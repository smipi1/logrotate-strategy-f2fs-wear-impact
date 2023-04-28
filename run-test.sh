#!/bin/bash

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

ROOTFS_IMG=rootfs.img
ROOTFS_SIZE=100M
ROOTFS_MOUNT_POINT=rootfs
TMPFS_MOUNT_POINT=${ROOTFS_MOUNT_POINT}/run
TMPFS_SIZE=10M
TMP_LOG_DIR=${TMPFS_MOUNT_POINT}/log
LOG_DIR=${ROOTFS_MOUNT_POINT}/var/log

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
insert CLEANUPS "sudo umount ${ROOTFS_MOUNT_POINT}"

echo "change root ownership of ${ROOTFS_MOUNT_POINT}..."
sudo chown -R ${USER}:${USER} ${ROOTFS_MOUNT_POINT} || error "cannot change ${ROOTFS_MOUNT_POINT} ownership to ${USER}"

echo "mounting tmpfs at ${TMPFS_MOUNT_POINT}..."
mkdir -p ${TMPFS_MOUNT_POINT} || error "cannot create ${TMPFS_MOUNT_POINT}..."
sudo mount -t tmpfs -o size=${TMPFS_SIZE} tmpfs ${TMPFS_MOUNT_POINT} || error "cannot mount tmpfs at ${TMPFS_MOUNT_POINT}"
sudo chown -R ${USER}:${USER} ${TMPFS_MOUNT_POINT} || error "cannot change ${TMPFS_MOUNT_POINT} ownership to ${USER}"
insert CLEANUPS "sudo umount ${TMPFS_MOUNT_POINT}"

echo "preparing directory structure..."
mkdir -p ${LOG_DIR} || error "cannot create ${LOG_DIR}"
mkdir -p ${TMP_LOG_DIR} || error "cannot create ${TMP_LOG_DIR}"

tree -ug rootfs

cleanup

