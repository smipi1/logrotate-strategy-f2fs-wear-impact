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
        ${CLEANUP}
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

bump_log() {
    touch ${LIVE_LOG}
    let DELTA_SIZE="$(numfmt --from=iec ${LOG_CHUNK_SIZE})"
    let CURRENT_SIZE="$(stat --printf='%s' ${LIVE_LOG})"
    let MIN_NEW_SIZE="$((${CURRENT_SIZE} + ${DELTA_SIZE}))"
    while [ "$(stat --printf='%s' ${LIVE_LOG})" -lt "${MIN_NEW_SIZE}" ]; do
        log "test: adding a line to the log chunk" >> ${LIVE_LOG}
    done
}

do_rotation() {
    logrotate --state=${LOGROTATE_STATE_FILE} ${LOGROTATE_CONFIG}
}

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
LOG_CHUNK_SIZE=20K
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

for i in {{1..100}}; do
    bump_log
    tree -sh ${ROOTFS_MOUNT_POINT}
    do_rotation
    tree -sh ${ROOTFS_MOUNT_POINT}
done

cp -a ${LOG_DIR} ./log-dir

cleanup

