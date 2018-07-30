#!/bin/sh

set -eu

TMP_TEST_IMAGE_FILE="/tmp/test_file.img"

QEMU_ARM_BIN="$(command -v qemu-arm-static || command -v qemu-arm)"

overlayfs_dir=""
rootfs_dir=""

RESULT=0

setup()
{
    overlayfs_dir="$(mktemp -d)"
    rootfs_dir="$(mktemp -d)"

    mount -t tmpfs none "${overlayfs_dir}"
    mkdir "${overlayfs_dir}/rom"
    mkdir "${overlayfs_dir}/up"
    mkdir "${overlayfs_dir}/work"

    mount "${ROOTFS_IMG}" "${overlayfs_dir}/rom"
    mount -t overlay overlay \
          -o "lowerdir=${overlayfs_dir}/rom,upperdir=${overlayfs_dir}/up,workdir=${overlayfs_dir}/work" \
          "${rootfs_dir}"

    cp "${QEMU_ARM_BIN}" "${rootfs_dir}/usr/bin/"

    mount --bind /proc "${rootfs_dir}/proc" 1> /dev/null
    ln -s ../proc/self/mounts "${rootfs_dir}/etc/mtab"

    dd if=/dev/zero of="${rootfs_dir}/${TMP_TEST_IMAGE_FILE}" bs=32M count=4 2> /dev/null
}

teardown()
{
    mounts="${rootfs_dir} ${overlayfs_dir}/rom ${overlayfs_dir}"

    if [ ! -d "${rootfs_dir}" ]; then
        return
    fi

    if grep -q "${rootfs_dir}/proc" /proc/mounts; then
        umount "${rootfs_dir}/proc" || RESULT=1
    fi

    for mount in ${mounts}; do
        if grep -q "${mount}" /proc/mounts; then
            umount "${mount}" || RESULT=1
        fi
        if [ -d "${mount}" ]; then
            rmdir "${mount}" || RESULT=1
        fi
    done
}

run_test()
{
    setup

    echo "Run: ${1}"
    if "${1}"; then
        echo "Result - OK"
    else
        echo "Result - ERROR"
	RESULT=1
    fi
    printf '\n'

    teardown
}

test_execute_busybox()
{
    ( chroot "${rootfs_dir}" /bin/busybox true && return 0 ) || return 1
}

test_execute_fdisk()
{
    ( chroot "${rootfs_dir}" /sbin/fdisk -l "${TMP_TEST_IMAGE_FILE}" 1> /dev/null && return 0 ) || return 1
}

test_execute_mkfs_ext4()
{
    ( chroot "${rootfs_dir}" /sbin/mkfs.ext4 "${TMP_TEST_IMAGE_FILE}" 1> /dev/null && return 0 ) || return 1
}

test_execute_resize2fs()
{
    test_execute_mkfs_ext4
    ( chroot "${rootfs_dir}" /usr/sbin/resize2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null && return 0 ) || return 1
}

test_execute_mkfs_f2fs()
{
    ( chroot "${rootfs_dir}" /usr/sbin/mkfs.f2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null && return 0 ) || return 1
}

test_execute_resizef2fs()
{
    test_execute_mkfs_f2fs
    ( chroot "${rootfs_dir}" /usr/sbin/resize.f2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null && return 0 ) || return 1
}

test_execute_mount()
{
   ( chroot "${rootfs_dir}" /bin/mount --version 1> /dev/null && return 0 ) || return 1
}

test_execute_rsync()
{
    ( chroot "${rootfs_dir}" /usr/bin/rsync --version 1> /dev/null && return 0 ) || return 1
}

usage()
{
cat <<-EOT
	Usage:   "${0}" [OPTIONS] <file.img>
	    -h   Print usage
	NOTE: This script requires root permissions to run.
EOT
}

trap teardown EXIT

while getopts ":h" options; do
    case "${options}" in
    h)
      usage
      exit 0
      ;;
    :)
      echo "Option -${OPTARG} requires an argument."
      exit 1
      ;;
    ?)
      echo "Invalid option: -${OPTARG}."
      exit 1
      ;;
    esac
done
shift "$((OPTIND - 1))"

if [ "${#}" -ne 1 ]; then
    echo "Missing argument <file.img>."
    usage
    exit 1
fi

ROOTFS_IMG="${*}"

if [ ! -r "${ROOTFS_IMG}" ]; then
    echo "Given rootfs image '${ROOTFS_IMG}' not found."
    usage
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Warning: this script requires root permissions."
    echo "Run this script again with 'sudo ${0}'."
    echo "See ${0} -h for more info."
    exit 1
fi

echo "Running tests on '${ROOTFS_IMG}'."

run_test test_execute_busybox
run_test test_execute_fdisk
run_test test_execute_mkfs_ext4
run_test test_execute_resize2fs
run_test test_execute_mkfs_f2fs
run_test test_execute_resizef2fs
run_test test_execute_mount
run_test test_execute_rsync

if [ "${RESULT}" -ne 0 ]; then
   echo "ERROR: There where failures testing '${ROOTFS_IMG}'."
   exit 1
fi

echo "All Ok"

exit 0
