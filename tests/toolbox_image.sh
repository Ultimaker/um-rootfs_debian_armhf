#!/bin/sh

set -eu

ARM_EMU_BIN="${ARM_EMU_BIN:-}"
TMP_TEST_IMAGE_FILE="/tmp/test_file.img"
SYSTEM_UPDATE_ENTRYPOINT="/sbin/startup.sh"

overlayfs_dir=""
rootfs_dir=""

result=0

exit_on_failure=false

setup()
{
    if [ ! -x "${ARM_EMU_BIN}" ]; then
        echo "Invalid or missing ARMv7 interpreter. Please set ARM_EMU_BIN to a valid interpreter."
        echo "Run 'tests/buildenv.sh' to check emulation status."
        exit 1
    fi

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

    touch "${rootfs_dir}/${ARM_EMU_BIN}"
    mount --bind -o ro "${ARM_EMU_BIN}" "${rootfs_dir}/${ARM_EMU_BIN}"

    mount --bind /proc "${rootfs_dir}/proc" 1> /dev/null
    ln -s ../proc/self/mounts "${rootfs_dir}/etc/mtab"

    dd if=/dev/zero of="${rootfs_dir}/${TMP_TEST_IMAGE_FILE}" bs=1 count=0 seek=128M 2> /dev/null
}

teardown()
{
    mounts="${rootfs_dir} ${overlayfs_dir}/rom ${overlayfs_dir}"

    if [ ! -d "${rootfs_dir}" ]; then
        return
    fi

    if [ -e "${rootfs_dir}/${ARM_EMU_BIN}" ]; then
        if grep -q "$(realpath "${rootfs_dir}/${ARM_EMU_BIN}")" "/proc/mounts"; then
            umount "${rootfs_dir}/${ARM_EMU_BIN}"
        fi
        if [ -f "${rootfs_dir}/${ARM_EMU_BIN}" ]; then
            unlink "${rootfs_dir}/${ARM_EMU_BIN}"
        fi
    fi

    if grep -q "${rootfs_dir}/proc" /proc/mounts; then
        umount "${rootfs_dir}/proc" || result=1
    fi

    for mount in ${mounts}; do
        if grep -q "${mount}" /proc/mounts; then
            umount "${mount}" || result=1
        fi
        if [ -d "${mount}" ]; then
            rmdir "${mount}" || result=1
        fi
    done
}

failure_exit()
{
    echo "Test exit per request."
    echo "When finished, the following is needed to cleanup!"
    echo "  sudo sh -c '\\"
    echo "    umount '${rootfs_dir}/${ARM_EMU_BIN}' && \\"
    echo "    unlink '${rootfs_dir}/${ARM_EMU_BIN}' && \\"
    echo "    umount '${rootfs_dir}/proc' && \\"
    echo "    umount '${rootfs_dir}' && \\"
    echo "    rmdir '${rootfs_dir}' && \\"
    echo "    umount '${overlayfs_dir}/rom' && \\"
    echo "    rmdir '${overlayfs_dir}/rom' && \\"
    echo "    umount '${overlayfs_dir}/' && \\"
    echo "    rmdir '${overlayfs_dir}/'"
    echo "  '"
    echo "The rootfs_dir of the failed test is at '${rootfs_dir}'."
    exit "${result}"
}

run_test()
{
    setup

    echo "Run: ${1}"
    if "${1}"; then
        echo "Result - OK"
    else
        echo "Result - ERROR"
        result=1
        if "${exit_on_failure}"; then
            failure_exit
        fi
    fi
    printf '\n'

    teardown
}

test_execute_busybox()
{
    chroot "${rootfs_dir}" /bin/busybox true
}

test_execute_fdisk()
{
    chroot "${rootfs_dir}" /sbin/fdisk -l "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
}

test_execute_mkfs_ext4()
{
    chroot "${rootfs_dir}" /sbin/mkfs.ext4 "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
}

test_execute_resize2fs()
{
    test_execute_mkfs_ext4
    chroot "${rootfs_dir}" /usr/sbin/resize2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
}

test_execute_mkfs_f2fs()
{
    chroot "${rootfs_dir}" /usr/sbin/mkfs.f2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
}

test_execute_resizef2fs()
{
    test_execute_mkfs_f2fs
    chroot "${rootfs_dir}" /usr/sbin/resize.f2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
}

test_execute_mount()
{
   chroot "${rootfs_dir}" /bin/mount --version 1> /dev/null
}

test_execute_rsync()
{
    chroot "${rootfs_dir}" /usr/bin/rsync --version 1> /dev/null
}

test_system_update_entrypoint()
{
    test -x "${rootfs_dir}${SYSTEM_UPDATE_ENTRYPOINT}"
}

usage()
{
cat <<-EOT
	Usage:   "${0}" [OPTIONS] <file.img>
	    -e   Stop consequtive tests on failure without cleanup
	    -h   Print usage
	NOTE: This script requires root permissions to run.
EOT
}

while getopts ":eh" options; do
    case "${options}" in
    e)
        exit_on_failure=true
        ;;
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
run_test test_system_update_entrypoint

if [ "${result}" -ne 0 ]; then
   echo "ERROR: There where failures testing '${ROOTFS_IMG}'."
   exit 1
fi

echo "All Ok"

exit 0
