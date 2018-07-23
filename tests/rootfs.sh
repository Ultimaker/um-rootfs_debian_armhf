#!/bin/sh

set -eux

ROOTFS_DIR="${ROOTFS_DIR:-./rootfs}"
TEST_IMAGE_FILE_PATH="$(mktemp)"
MTAB_FILE="/etc/mtab"
RUN_SUDO=""
QEMU_STATIC_BIN="$(command -v qemu-arm-static)"

setup()
{
    if [ ! -x "${ROOTFS_DIR}${QEMU_STATIC_BIN}" ]; then
        "${RUN_SUDO}" cp "${QEMU_STATIC_BIN}" "${ROOTFS_DIR}/usr/bin/"
    fi

    "${RUN_SUDO}" mount --bind --read-only /dev "${ROOTFS_DIR}/dev" 1> /dev/null || return 1

    dd if=/dev/zero of="${TEST_IMAGE_FILE_PATH}" bs=32M count=4 || return 1
    "${RUN_SUDO}" mount --bind /tmp "${ROOTFS_DIR}/tmp" 1> /dev/null || return 1

    "${RUN_SUDO}" touch "${ROOTFS_DIR}${MTAB_FILE}" 1> /dev/null || return 1
    "${RUN_SUDO}" mount --bind --read-only "${MTAB_FILE}" "${ROOTFS_DIR}${MTAB_FILE}"
}

teardown()
{
    if [ "${ROOTFS_DIR}" != "" ]; then
        if [ "$(mount | grep "${ROOTFS_DIR}/dev")" != "" ];then
            "${RUN_SUDO}" umount "${ROOTFS_DIR}/dev" || true
        fi

        if [ "$(mount | grep "${ROOTFS_DIR}/tmp")" != "" ];then
            "${RUN_SUDO}" umount "${ROOTFS_DIR}/tmp" || true
        fi

        if [ "$(mount | grep "${ROOTFS_DIR}${MTAB_FILE}")" != "" ];then
            "${RUN_SUDO}" umount "${ROOTFS_DIR}${MTAB_FILE}" || true
        fi

        if "${RUN_SUDO}" find "${ROOTFS_DIR}/etc" -name "$(basename "${MTAB_FILE}")" 1> /dev/null; then
            "${RUN_SUDO}" rm -f "${ROOTFS_DIR}${MTAB_FILE}" || true
        fi

        if [ -f "${ROOTFS_DIR}${QEMU_STATIC_BIN}" ]; then
            "${RUN_SUDO}" rm -f "${ROOTFS_DIR}${QEMU_STATIC_BIN}" || true
        fi
    fi

    if "${RUN_SUDO}" find "/tmp" -name "$(basename "${TEST_IMAGE_FILE_PATH}")" 1> /dev/null; then
        rm -f "${TEST_IMAGE_FILE_PATH}" || true
    fi
}

run_test()
{
    if ! setup; then
        printf "Cannot run tests, unable to complete test setup\\n"
        teardown
        exit 1
    fi

    if "$1"; then
        printf "Run: %s - OK\\n" "${1}"
    else
        printf "Run: %s - ERROR\\n" "${1}"
    fi
    teardown
}

test_execute_resize2fs()
{
    mkfs.ext4 "${TEST_IMAGE_FILE_PATH}" 1> /dev/null || return 1
    ( "${RUN_SUDO}" chroot "${ROOTFS_DIR}" /sbin/resize2fs "${TEST_IMAGE_FILE_PATH}" 1> /dev/null && return 0 ) || return 1
}

test_execute_fdisk()
{
    ( "${RUN_SUDO}" chroot "${ROOTFS_DIR}" /sbin/fdisk --version 1> /dev/null && return 0 ) || return 1
}

test_execute_mount()
{
   ( "${RUN_SUDO}" chroot "${ROOTFS_DIR}" /bin/mount --version 1> /dev/null && return 0 ) || return 1
}

test_execute_rsync()
{
    ( "${RUN_SUDO}" chroot "${ROOTFS_DIR}" /usr/bin/rsync --version 1> /dev/null && return 0 ) || return 1
}

test_execute_busybox()
{
    ( "${RUN_SUDO}" chroot "${ROOTFS_DIR}" /bin/busybox --help 1> /dev/null && return 0 ) || return 1
}

test_execute_mkfs_ext4()
{
    ( "${RUN_SUDO}" chroot "${ROOTFS_DIR}" /sbin/mkfs.ext4 "${TEST_IMAGE_FILE_PATH}" 1> /dev/null && return 0 ) || return 1
}

test_execute_mkfs_f2fs()
{
    ( "${RUN_SUDO}" chroot "${ROOTFS_DIR}" /sbin/mkfs.f2fs "${TEST_IMAGE_FILE_PATH}" 1> /dev/null && return 0 ) || return 1
}

usage()
{
cat <<-EOT
    Usage:   "${0}" [OPTIONS]
        -h   Print usage
        -r   Path to the bootstrapped rootfs that needs to be tested.
    NOTE: This script requires root permissions to run.
EOT
}

if [ "$(id -u)" != "0" ]; then
    RUN_SUDO="sudo"
fi

while getopts ":hr:" options; do
  case "${options}" in
    h)
      usage
      exit 0
      ;;
    r)
      ROOTFS_DIR="${OPTARG}"
      ;;
    :)
      printf "Option -%s requires an argument.\\n" "${OPTARG}"
      exit 1
      ;;
    \?)
      printf "Invalid option: -%s\\n" "${OPTARG}"
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"


if [ ! -d "${ROOTFS_DIR}" ]; then
    printf "Given rootfs directory (%s) not found\\n" "${ROOTFS_DIR}"
    usage
    exit 1
fi

run_test test_execute_resize2fs
run_test test_execute_fdisk
run_test test_execute_mount
run_test test_execute_rsync
run_test test_execute_busybox
run_test test_execute_mkfs_ext4
run_test test_execute_mkfs_f2fs

exit 0