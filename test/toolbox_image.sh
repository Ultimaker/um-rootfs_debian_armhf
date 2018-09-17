#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

# shellcheck source=test/include/chroot_env.sh
. "test/include/chroot_env.sh"

SYSTEM_UPDATE_DIR="/etc/system_update"
SYSTEM_EXECUTABLE_DIR="/sbin"
PREPARE_DISK_COMMAND="${SYSTEM_UPDATE_DIR}.d/30_prepare_disk.sh"
UPDATE_FILES_COMMAND="${SYSTEM_UPDATE_DIR}.d/50_update_files.sh"
START_UPDATE_COMMAND="${SYSTEM_EXECUTABLE_DIR}/start_update.sh"
JEDI_PARTITION_TABLE_FILE="${SYSTEM_UPDATE_DIR}/jedi_emmc_sfdisk.table"
JEDI_EXCLUDE_LIST_FILE="${SYSTEM_UPDATE_DIR}/jedi_update_exclude_list.txt"
TMP_TEST_IMAGE_FILE="/tmp/test_file.img"

TEST_OUTPUT_FILE="$(mktemp -d)/test_results_$(basename "${0%.sh}").txt"

toolbox_image=""
toolbox_root_dir=""

exit_on_failure=false
result=0


setup()
{
    toolbox_root_dir="$(mktemp -d -t "um-update-toolbox.XXXXXXXXXX")"
    setup_chroot_env "${toolbox_image}" "${toolbox_root_dir}"

    dd if=/dev/zero of="${toolbox_root_dir}/${TMP_TEST_IMAGE_FILE}" bs=1 count=0 seek=128M
}

teardown()
{
    if [ -f "${toolbox_root_dir}/${TMP_TEST_IMAGE_FILE}" ]; then
        unlink "${toolbox_root_dir}/${TMP_TEST_IMAGE_FILE}"
    fi

    teardown_chroot_env "${toolbox_root_dir}"

    if grep -q "${toolbox_root_dir}" "/proc/mounts"; then
        umount "${toolbox_root_dir}"
    fi

    if [ -d "${toolbox_root_dir}" ] && [ -z "${toolbox_root_dir##/*um-update-toolbox*}" ]; then
        rm -rf "${toolbox_root_dir}"
    fi
}

failure_exit()
{
    echo "Test exit per request."
    echo "When finished, the following is needed to cleanup!"
    echo "  sudo sh -c '\\"
    echo "    unlink '${toolbox_root_dir}/${TMP_TEST_IMAGE_FILE}' && \\"
    echo "    umount '${toolbox_root_dir}' && \\"
    echo "    rm -rf '${toolbox_root_dir}' && \\"

    failure_exit_chroot_env

    echo "  '"
    echo "The rootfs_dir of the failed test is at '${toolbox_root_dir}'."
    exit "${result}"
}

cleanup()
{
    if "${exit_on_failure}"; then
        failure_exit
    else
        teardown
    fi
}

run_test()
{
    setup

    echo "________________________________________________________________________________"
    echo
    echo "Run: ${1}"
    echo
    echo
    if "${1}"; then
        echo "Result - OK"
        echo "OK    - ${1}" >> "${TEST_OUTPUT_FILE}"
    else
        echo "Result - ERROR"
        echo "ERROR - ${1}" >> "${TEST_OUTPUT_FILE}"
        result=1
        if "${exit_on_failure}"; then
            exit "${result}"
        fi
    fi
    echo "________________________________________________________________________________"

    teardown
}

test_execute_busybox()
{
    chroot "${toolbox_root_dir}" /bin/busybox true || return 1
}

test_execute_sha512()
{
    chroot "${toolbox_root_dir}" sha512sum /bin/busybox > "${toolbox_root_dir}${TMP_TEST_IMAGE_FILE}" || return 1
    chroot "${toolbox_root_dir}" sha512sum -csw "${TMP_TEST_IMAGE_FILE}" || return 1
}

test_execute_sfdisk()
{
    chroot "${toolbox_root_dir}" /sbin/sfdisk -l "${TMP_TEST_IMAGE_FILE}" || return 1
}

test_execute_mkfs_ext4()
{
    chroot "${toolbox_root_dir}" /sbin/mkfs.ext4 "${TMP_TEST_IMAGE_FILE}" || return 1
    chroot "${toolbox_root_dir}" /sbin/fsck.ext4 -fn "${TMP_TEST_IMAGE_FILE}" || return 1
}

test_execute_resize2fs()
{
    test_execute_mkfs_ext4 || return 1
    chroot "${toolbox_root_dir}" /usr/sbin/resize2fs "${TMP_TEST_IMAGE_FILE}" || return 1
    chroot "${toolbox_root_dir}" /sbin/fsck.ext4 -fn "${TMP_TEST_IMAGE_FILE}" || return 1
}

test_execute_mkfs_f2fs()
{
    chroot "${toolbox_root_dir}" /usr/sbin/mkfs.f2fs "${TMP_TEST_IMAGE_FILE}" || return 1
    chroot "${toolbox_root_dir}" /usr/sbin/fsck.f2fs "${TMP_TEST_IMAGE_FILE}" || return 1
}

test_execute_resizef2fs()
{
    test_execute_mkfs_f2fs || return 1
    chroot "${toolbox_root_dir}" /usr/sbin/resize.f2fs "${TMP_TEST_IMAGE_FILE}" || return 1
    chroot "${toolbox_root_dir}" /usr/sbin/fsck.f2fs "${TMP_TEST_IMAGE_FILE}" || return 1
}

test_execute_mount()
{
   chroot "${toolbox_root_dir}" /bin/mount --version || return 1
}

test_execute_rsync()
{
    chroot "${toolbox_root_dir}" /usr/bin/rsync --version || return 1
}

test_start_update_command()
{
    test -x "${toolbox_root_dir}${START_UPDATE_COMMAND}" || return 1
    chroot "${toolbox_root_dir}" "${START_UPDATE_COMMAND}" "-h" || return 1
}

test_prepare_disk_command()
{
    test -x "${toolbox_root_dir}${PREPARE_DISK_COMMAND}" || return 1
    chroot "${toolbox_root_dir}" "${PREPARE_DISK_COMMAND}" "-h" || return 1
}

test_update_files_command()
{
    test -x "${toolbox_root_dir}${UPDATE_FILES_COMMAND}" || return 1
    chroot "${toolbox_root_dir}" "${UPDATE_FILES_COMMAND}" "-h" || return 1
}

test_jedi_exclude_list_exists()
{
    test -f "${toolbox_root_dir}${JEDI_EXCLUDE_LIST_FILE}" || return 1
}

test_jedi_partition_table_file_exists()
{
    test -f "${toolbox_root_dir}${JEDI_PARTITION_TABLE_FILE}" || return 1
}

usage()
{
cat <<-EOT
    Usage:   "${0}" [OPTIONS] <toolbox image file>
        -e   Stop consecutive tests on failure without cleanup
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

toolbox_image="${*}"

if [ ! -r "${toolbox_image}" ]; then
    echo "Given toolbox image file '${toolbox_image}' not found."
    usage
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Warning: this script requires root permissions."
    echo "Run this script again with 'sudo ${0}'."
    echo "See ${0} -h for more info."
    exit 1
fi

trap cleanup EXIT

echo "Running tests on '${toolbox_image}'."
run_test test_execute_busybox
run_test test_execute_sha512
run_test test_execute_sfdisk
run_test test_execute_mkfs_ext4
run_test test_execute_resize2fs
run_test test_execute_mkfs_f2fs
run_test test_execute_resizef2fs
run_test test_execute_mount
run_test test_execute_rsync
run_test test_start_update_command
run_test test_prepare_disk_command
run_test test_update_files_command
run_test test_jedi_exclude_list_exists
run_test test_jedi_partition_table_file_exists

echo
echo "Test results:"
echo
cat "${TEST_OUTPUT_FILE}"
echo "________________________________________________________________________________"

if [ "${result}" -ne 0 ]; then
   exit 1
fi

exit 0
