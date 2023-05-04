#!/bin/bash

set -o pipefail
trap cleanup INT

# Parameterizable variable (via environment)
MIN_NEW_LOG_SIZE_TO_ROTATE=${MIN_NEW_LOG_SIZE_TO_ROTATE:-1} # Size threshold in tmpfs to rotate
                                                            # 1B effectively means always rotate
MIN_LOG_SIZE_TO_ROTATE=${MIN_LOG_SIZE_TO_ROTATE:-1M}        # Size threshold in f2fs to rotate
LOG_FILES_TO_KEEP=${LOG_FILES_TO_KEEP:-26}                  # Number of log files to maintain in f2fs
ROTATION_COUNT=${ROTATION_COUNT:-1}                         # Number of full f2fs rotations to test with
COMPRESS=${COMPRESS:-lz4}                                   # Compression app to use
COMPRESS_OPTS=${COMPRESS_OPTS:--3}                          # Compression options to pass to compression app
ADD_LOGROTATE_DIRECTIVE=${ADD_LOGROTATE_DIRECTIVE:-}        # Optional additional directive on f2fs rotation
SYNC_ON_COMPRESS=${SYNC_ON_COMPRESS:-}                      # Optionally sync on every compress and append
SYNC_ON_ROTATE=${SYNC_ON_ROTATE:-}                          # Optionally sync on every f2fs rotation

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

grow_syslog() {
    touch ${LIVE_LOG}
    local MESSAGE_COUNT="$(( (${LOG_ACCRETION_PER_ROTATION} + ${BYTES_PER_MESSAGE} - 1 ) / ${BYTES_PER_MESSAGE} ))"
    local CURRENT_SIZE="$(stat --printf='%s' ${LIVE_LOG})"
    ${GENERATE_LOG_MESSAGES} -v start_seq=${SEQ_NR} -v message_count=${MESSAGE_COUNT} >> ${LIVE_LOG}
    let "SEQ_NR += ${MESSAGE_COUNT}"
    let "SIZE_LOGGED+=${MESSAGE_COUNT}*${BYTES_PER_MESSAGE}"
}

do_rotation() {
    logrotate --state=${LOGROTATE_STATE_FILE} ${LOGROTATE_CONFIG}
}

space_separated_to_csv() {
    sed 's/ \+/,/g'
}

print_stats_header() {
    echo "seconds_elapsed size_logged files_in_tmp_log_dir size_in_tmp_log_dir files_in_var_log_dir size_in_var_log_dir major_number minor_number device_name reads_completed_successfully reads_merged sectors_read time_spent_reading_ms writes_completed writes_merged sectors_written time_spent_writing_ms ios_corrently_in_progress time_spent_doing_ios_ms weighted_time_spent_doing_ios discards_completed_successfully discards_merged sectors_discarded time_spent_discarding flush_requests_completed_successfully time_spent_flusing" | space_separated_to_csv >${STATS}
}

print_stats() {
    local FILES_IN_TMP_LOG_DIR=$(ls -1 ${TMP_LOG_DIR} | wc -l)
    local SIZE_IN_TMP_LOG_DIR=$(du -s ${TMP_LOG_DIR} | awk '{print $1 * 1024}')
    local FILES_IN_VAR_LOG_DIR=$(ls -1 ${LOG_DIR} | wc -l)
    local SIZE_IN_VAR_LOG_DIR=$(du -s ${LOG_DIR} | awk '{print $1 * 1024}')
    local DISKSTATS=$(grep "${LOOP_DEVICE_NAME}" /proc/diskstats)
    ( \
        echo -n "${SECONDS_ELAPSED} ${SIZE_LOGGED} ${FILES_IN_TMP_LOG_DIR} ${SIZE_IN_TMP_LOG_DIR} ${FILES_IN_VAR_LOG_DIR} ${SIZE_IN_VAR_LOG_DIR} "; \
        grep "${LOOP_DEVICE_NAME}" /proc/diskstats \
    ) | space_separated_to_csv >>${STATS}
}

decompress_kept_logs() {
    (cd ${LOG_DIR} && ls -1vr | xargs cat | ${COMPRESS} -dc - -)
}

has_complete_sequence() {
    awk -F ':' '
        BEGIN {
            message_count = 0
        }
        // {
            seq_nr = int($1);
            message_count++;
            if(length(prev_seq_nr) == 0) {
                # skip the first record
            } else {
                delta = seq_nr - prev_seq_nr;
                if(delta != 1) {
                    # jump in sequence
                    printf("error: sequence incorrect at message %d: expected delta=1, but got delta=%d\n", message_count, delta);
                    exit 1
                }
            }
            prev_seq_nr = seq_nr
        }
    '
}

print_results() {
    echo    "RAM log rotates on:  ${MIN_NEW_LOG_SIZE_TO_ROTATE}B"
    echo    "eMMC log rotates on: ${MIN_LOG_SIZE_TO_ROTATE}B"
    echo    "Log files to keep:   ${LOG_FILES_TO_KEEP}"
    echo    "logrotate call rate: ${LOGROTATE_RATE_SECONDS} s"
    echo    "compression used:    ${COMPRESS} ${COMPRESS_OPTS}"
    echo    "compression rate:    ${COMPRESSION_RATE} %"
    echo -n "sync on compression: "; [ -n "${SYNC_ON_COMPRESS}" ] && echo "yes" || echo "no"
    echo -n "sync on rotation:    "; [ -n "${SYNC_ON_ROTATE}" ] && echo "yes" || echo "no"
    echo    "total rotations:     ${ROTATION_COUNT}"
    echo    "all messages kept:   ${KEPT_LOG_SEQUENCE_COMPLETE}"
    ./analyze.py ${STATS}
}

RESULTS_ROOT_DIR=results
ROOTFS_IMG=rootfs.img
ROOTFS_SIZE=100M
ROOTFS_MOUNT_POINT=rootfs
TMPFS_MOUNT_POINT=${ROOTFS_MOUNT_POINT}/run
TMPFS_SIZE=10M
TMP_LOG_DIR=${TMPFS_MOUNT_POINT}/log
VAR_DIR=${ROOTFS_MOUNT_POINT}/var
LOG_DIR=${VAR_DIR}/log
LIVE_LOG=${TMP_LOG_DIR}/messages
KEEP_LOG=${LOG_DIR}/messages.lz4
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
GENERATE_LOG_MESSAGES=./generate-64-byte-syslog-messages.awk
BYTES_PER_MESSAGE=$(${GENERATE_LOG_MESSAGES} | wc -c)
FULL_KEEP_ROTATION_SIZE=$(( (${LOG_FILES_TO_KEEP} + 1) * $( numfmt --from=iec ${MIN_LOG_SIZE_TO_ROTATE} ) ))
RESULTS_DIR=${RESULTS_ROOT_DIR}/ram_rotate_every_${LOGROTATE_RATE_SECONDS}s.compress_${COMPRESS}${COMPRESS_OPTS//-/_}.var_rotate_every_${MIN_LOG_SIZE_TO_ROTATE}B.keep_${LOG_FILES_TO_KEEP}.${ROTATION_COUNT}_rotations${ADD_LOGROTATE_DIRECTIVE:+.${ADD_LOGROTATE_DIRECTIVE}}${SYNC_ON_COMPRESS:+.sync_on_compress}${SYNC_ON_ROTATE:+.sync_on_rotate}
STATS=${RESULTS_DIR}/teststats.log.csv

echo "creating ${RESULTS_DIR}..."
mkdir -p ${RESULTS_DIR} || error "cannot create ${RESULTS_DIR}"

echo "creating ${ROOTFS_IMG}..."
dd if=/dev/zero of=${ROOTFS_IMG} count=1 bs=${ROOTFS_SIZE} status=none || error "cannot create ${ROOTFS_IMG}"

echo -n "finding free loop device... "
LOOP_DEVICE="$(sudo losetup -f)"
[ -n "${LOOP_DEVICE}" ] || error "cannot find free loop device"
echo "found ${LOOP_DEVICE}"
LOOP_DEVICE_NAME=$(basename ${LOOP_DEVICE})

echo "attach ${LOOP_DEVICE} to ${ROOTFS_IMG}..."
sudo losetup ${LOOP_DEVICE} ${ROOTFS_IMG} || error "cannot attach loop device"
insert CLEANUPS "sudo losetup -d ${LOOP_DEVICE}"

echo "create an F2FS file system image in ${LOOP_DEVICE}..."
sudo mkfs.f2fs -q -f ${LOOP_DEVICE} || error "cannot create F2FS image"

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
LIVE_LOG=$(realpath ${LIVE_LOG}) \
KEEP_LOG=$(realpath ${KEEP_LOG}) \
MIN_NEW_LOG_SIZE_TO_ROTATE=${MIN_NEW_LOG_SIZE_TO_ROTATE} \
MIN_LOG_SIZE_TO_ROTATE=${MIN_LOG_SIZE_TO_ROTATE} \
LOG_FILES_TO_KEEP=${LOG_FILES_TO_KEEP} \
COMPRESS=${COMPRESS} \
COMPRESS_OPTS=${COMPRESS_OPTS} \
ADD_LOGROTATE_DIRECTIVE=${ADD_LOGROTATE_DIRECTIVE} \
SYNC_ON_COMPRESS_CMD="${SYNC_ON_COMPRESS:+sync -d ${KEEP_LOG}}" \
SYNC_ON_ROTATE_CMD="${SYNC_ON_ROTATE:+sync -d ${KEEP_LOG}.*}" \
    envsubst \
        <${LOGROTATE_TEMPLATE} \
        >${LOGROTATE_CONFIG} \
    || error "cannot configure logrotate"
SIZE_LOGGED=0
SECONDS_ELAPSED=0
print_stats_header
print_stats
i=0
while [ -z "${COMPRESS_COUNT}" ] || [ "${i}" -lt "${COMPRESS_COUNT}" ]; do
    let "SECONDS_ELAPSED += ${LOGROTATE_RATE_SECONDS}"
    grow_syslog
    do_rotation
    if [ -z "${COMPRESS_COUNT}" ]; then
        COMPRESSED_ROTATION_SIZE=$(${COMPRESS} ${COMPRESS_OPT} -c ${LIVE_LOG}.1 | wc -c)
        let "COMPRESS_COUNT = ${ROTATION_COUNT} * ${FULL_KEEP_ROTATION_SIZE} / ${COMPRESSED_ROTATION_SIZE}"
        let "COMPRESSION_RATE = ( ${SIZE_LOGGED} - ${COMPRESSED_ROTATION_SIZE} ) * 100 / ${SIZE_LOGGED}"
    fi
    print_stats
    printf "running test: $((${i} * 100 / ${COMPRESS_COUNT})) %% complete\r"
    [ -n "${SLEEP_PER_CYCLE}" ] && sleep ${SLEEP_PER_CYCLE}
    let "i++"
done
echo


echo "testing for complete compressed log sequence in ${LOG_DIR} ..."
if decompress_kept_logs | has_complete_sequence; then
    KEPT_LOG_SEQUENCE_COMPLETE="yes"
else
    KEPT_LOG_SEQUENCE_COMPLETE="no"
fi

echo "adding results to ${RESULTS_DIR} ..."
cp ${LOGROTATE_CONFIG} ${RESULTS_DIR}
print_results | tee ${RESULTS_DIR}/summary.txt

cleanup


