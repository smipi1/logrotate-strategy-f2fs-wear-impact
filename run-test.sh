#!/bin/bash

set -o pipefail
trap cleanup INT

insert() {
    local -n ARRAY=$1; shift
    ARRAY=("$@" "${ARRAY[@]}")
}

cleanup() {
    echo
    echo "cleaning up:"
    for CLEANUP in "${CLEANUPS[@]}"; do
        echo "    ${CLEANUP} ..."
        if ! ${CLEANUP}; then
            sleep 2
            echo "    retry: ${CLEANUP} ..."
            ${CLEANUP}
        fi
    done
    echo "    done"
}

detach_loop_device() {
    sudo losetup -d ${LOOP_DEVICE}
}

error() {
    echo
    echo "error: $*" >&2
    cleanup
    exit 1
}

log() {
    let "SEQ_NR += 1"
    printf "%010d: %s\n" ${SEQ_NR} "$*"
}

accrete_log_for_one_rotation() {
    touch ${LIVE_LOG}
    let CURRENT_SIZE="$(stat --printf='%s' ${LIVE_LOG})"
    let MIN_NEW_SIZE="$((${CURRENT_SIZE} + ${LOG_ACCRETION_PER_ROTATION}))"
    while [ "$(stat --printf='%s' ${LIVE_LOG})" -lt "${MIN_NEW_SIZE}" ]; do
        log "one representative syslog message accreted to the log" >> ${LIVE_LOG}
    done
}

do_rotation() {
    logrotate --state=${LOGROTATE_STATE_FILE} ${LOGROTATE_CONFIG}
}

STATS=stats.csv
ROOTFS_IMG=rootfs.img
ROOTFS_SIZE=100M
ROOTFS_MOUNT_POINT=rootfs
TMPFS_MOUNT_POINT=${ROOTFS_MOUNT_POINT}/run
TMPFS_SIZE=10M
TMP_LOG_DIR=${TMPFS_MOUNT_POINT}/log
VAR_DIR=${ROOTFS_MOUNT_POINT}/var
LOG_DIR=${VAR_DIR}/log
LIVE_LOG=${TMP_LOG_DIR}/messages
OLD_LOG=${LOG_DIR}/messages.lz4

LOG_FILL_RATE_SIZE_HUMAN=20K
LOG_FILL_RATE_SIZE=$(numfmt --from=iec ${LOG_FILL_RATE_SIZE_HUMAN})
LOG_FILL_RATE_MINUTES=5
LOG_FILL_RATE_SECONDS=$((${LOG_FILL_RATE_MINUTES}*60))
ACCEPTABLE_LOG_LOSS_MINUTES=5
ACCEPTABLE_LOG_LOSS_SECONDS=$((${ACCEPTABLE_LOG_LOSS_MINUTES}*60))
LOGROTATE_RATE_SECONDS=${ACCEPTABLE_LOG_LOSS_SECONDS}
LOG_ACCRETION_PER_ROTATION=$((${LOG_FILL_RATE_SIZE}*${LOGROTATE_RATE_SECONDS}/${LOG_FILL_RATE_SECONDS}))
LOGROTATE_TEMPLATE=logrotate.template
ETC_DIR=${ROOTFS_MOUNT_POINT}/etc
LOGROTATE_CONFIG=${ETC_DIR}/logrotate.config
LOGROTATE_STATE_FILE=${VAR_DIR}/logrotate.state

echo "creating ${ROOTFS_IMG}..."
dd if=/dev/zero of=${ROOTFS_IMG} count=1 bs=${ROOTFS_SIZE} || error "cannot create ${ROOTFS_IMG}"

echo -n "finding free loop device... "
LOOP_DEVICE="$(sudo losetup -f)"
[ -n "${LOOP_DEVICE}" ] || error "cannot find free loop device"
echo "found ${LOOP_DEVICE}"
LOOP_DEVICE_NAME=$(basename ${LOOP_DEVICE})

echo "attach ${LOOP_DEVICE} to ${ROOTFS_IMG}..."
sudo losetup ${LOOP_DEVICE} ${ROOTFS_IMG} || error "cannot attach loop device"
insert CLEANUPS "sudo losetup -d ${LOOP_DEVICE}"

echo "create an F2FS file system image in ${LOOP_DEVICE}..."
sudo mkfs.f2fs -f ${LOOP_DEVICE} || error "cannot create F2FS image"

echo "mount F2FS file system at ${ROOTFS_MOUNT_POINT}..."
sudo mount ${LOOP_DEVICE} -o loop ${ROOTFS_MOUNT_POINT} || error "cannot mount ${LOOP_DEVICE} at ${ROOTFS_MOUNT_POINT}"
insert CLEANUPS "sudo umount -f ${ROOTFS_MOUNT_POINT}"

echo "change root ownership of ${ROOTFS_MOUNT_POINT}..."
sudo chown -R ${USER}:${USER} ${ROOTFS_MOUNT_POINT} || error "cannot change ${ROOTFS_MOUNT_POINT} ownership to ${USER}"

echo "mounting tmpfs at ${TMPFS_MOUNT_POINT}..."
mkdir -p ${TMPFS_MOUNT_POINT} || error "cannot create ${TMPFS_MOUNT_POINT}..."
sudo mount -t tmpfs -o size=${TMPFS_SIZE} tmpfs ${TMPFS_MOUNT_POINT} || error "cannot mount tmpfs at ${TMPFS_MOUNT_POINT}"
insert CLEANUPS "sudo umount -f ${TMPFS_MOUNT_POINT}"
sudo chown -R ${USER}:${USER} ${TMPFS_MOUNT_POINT} || error "cannot change ${TMPFS_MOUNT_POINT} ownership to ${USER}"

echo "preparing directory structure..."
mkdir -p ${ETC_DIR} || error "cannot create ${ETC_DIR}"
mkdir -p ${LOG_DIR} || error "cannot create ${LOG_DIR}"
mkdir -p ${TMP_LOG_DIR} || error "cannot create ${TMP_LOG_DIR}"

echo "configuring logrotate..."
LIVE_LOG=$(realpath ${LIVE_LOG}) OLD_LOG=$(realpath ${OLD_LOG}) envsubst <${LOGROTATE_TEMPLATE} >${LOGROTATE_CONFIG} || error "cannot configure logrotate"

space_separated_to_csv() {
    sed 's/ \+/,/g'
}

print_stats_header() {
    echo "seconds_elapsed files_in_tmp_log_dir size_in_tmp_log_dir files_in_var_log_dir size_in_var_log_dir major_number minor_number device_name reads_completed_successfully reads_merged sectors_read time_spent_reading_ms writes_completed writes_merged sectors_written time_spent_writing_ms ios_corrently_in_progress time_spent_doing_ios_ms weighted_time_spent_doing_ios discards_completed_successfully discards_merged sectors_discarded time_spent_discarding flush_requests_completed_successfully time_spent_flusing" | space_separated_to_csv >${STATS}
}

print_stats() {
    local FILES_IN_TMP_LOG_DIR=$(ls -1 ${TMP_LOG_DIR} | wc -l)
    local SIZE_IN_TMP_LOG_DIR=$(du -s ${TMP_LOG_DIR} | awk '{print $1 * 1024}')
    local FILES_IN_VAR_LOG_DIR=$(ls -1 ${LOG_DIR} | wc -l)
    local SIZE_IN_VAR_LOG_DIR=$(du -s ${LOG_DIR} | awk '{print $1 * 1024}')
    local DISKSTATS=$(grep "${LOOP_DEVICE_NAME}" /proc/diskstats)
    ( \
        echo -n "${SECONDS_ELAPSED} ${FILES_IN_TMP_LOG_DIR} ${SIZE_IN_TMP_LOG_DIR} ${FILES_IN_VAR_LOG_DIR} ${SIZE_IN_VAR_LOG_DIR} "; \
        grep "${LOOP_DEVICE_NAME}" /proc/diskstats \
    ) | space_separated_to_csv >>${STATS}
}

SECONDS_ELAPSED=0
print_stats_header
print_stats
for i in {{1..1000}}; do
    let "SECONDS_ELAPSED += ${LOGROTATE_RATE_SECONDS}"
    accrete_log_for_one_rotation
    do_rotation
    print_stats
    echo ${SECONDS_ELAPSED}: ${TMP_LOG_DIR}/* ${LOG_DIR}/*
done

cp -a ${LOG_DIR} ./log-dir

cleanup

