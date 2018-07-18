#!/bin/sh

set -eux

ROOTFS_DIR="${ROOTFS_DIR:-./rootfs}"
TEST_IMAGE_FILE_PATH="$(mktemp)"
MTAB_FILE="/etc/mtab"

QEMU_STATIC_BIN="$(command -v qemu-arm-static)"

setup()
{
    if [ ! -x "${ROOTFS_DIR}${QEMU_STATIC_BIN}" ]; then
        cp "${QEMU_STATIC_BIN}" "${ROOTFS_DIR}/usr/bin/"
    fi

    mount --bind --read-only /dev "${ROOTFS_DIR}/dev" 1> /dev/null || return 1

    dd if=/dev/zero of="${TEST_IMAGE_FILE_PATH}" bs=32M count=4 || return 1
    mount --bind /tmp "${ROOTFS_DIR}/tmp" 1> /dev/null || return 1

    touch "${ROOTFS_DIR}${MTAB_FILE}" 1> /dev/null || return 1
    mount --bind --read-only "${MTAB_FILE}" "${ROOTFS_DIR}${MTAB_FILE}"
}

teardown()
{
    if [ "${ROOTFS_DIR}" != "" ]; then
        if [ "$(mount | grep "${ROOTFS_DIR}/dev")" != "" ];then
            umount "${ROOTFS_DIR}/dev" || true
        fi

        if [ "$(mount | grep "${ROOTFS_DIR}/tmp")" != "" ];then
            umount "${ROOTFS_DIR}/tmp" || true
        fi

        if [ "$(mount | grep "${ROOTFS_DIR}${MTAB_FILE}")" != "" ];then
            umount "${ROOTFS_DIR}${MTAB_FILE}" || true
        fi

        if find "${ROOTFS_DIR}/etc" -name "$(basename "${MTAB_FILE}")" 1> /dev/null; then
            rm -f "${ROOTFS_DIR}${MTAB_FILE}" || true
        fi

        if [ -f "${ROOTFS_DIR}${QEMU_STATIC_BIN}" ]; then
            rm -f "${ROOTFS_DIR}${QEMU_STATIC_BIN}" || true
        fi
    fi

    if find "/tmp" -name "$(basename "${TEST_IMAGE_FILE_PATH}")" 1> /dev/null; then
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
    ( chroot "${ROOTFS_DIR}" /sbin/resize2fs "${TEST_IMAGE_FILE_PATH}" 1> /dev/null && return 0 ) || return 1
}

test_execute_fdisk()
{
    ( chroot "${ROOTFS_DIR}" /sbin/fdisk --version 1> /dev/null && return 0 ) || return 1
}

test_execute_mount()
{
   ( chroot "${ROOTFS_DIR}" /bin/mount --version 1> /dev/null && return 0 ) || return 1
}

test_execute_rsync()
{
    ( chroot "${ROOTFS_DIR}" /usr/bin/rsync --version 1> /dev/null && return 0 ) || return 1
}

test_execute_busybox()
{
    ( chroot "${ROOTFS_DIR}" /bin/busybox --help 1> /dev/null && return 0 ) || return 1
}

test_execute_mkfs_ext4()
{
    ( chroot "${ROOTFS_DIR}" /sbin/mkfs.ext4 "${TEST_IMAGE_FILE_PATH}" 1> /dev/null && return 0 ) || return 1
}

test_execute_mkfs_f2fs()
{
    ( chroot "${ROOTFS_DIR}" /sbin/mkfs.f2fs "${TEST_IMAGE_FILE_PATH}" 1> /dev/null && return 0 ) || return 1
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
    printf "Make sure this script is run with root permissions\\n"
    usage
    exit 1
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