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

# Common directory variables
SBINDIR="/sbin"
SYSCONFDIR="${SYSCONFDIR:-/etc}"

ARM_EMU_BIN="${ARM_EMU_BIN:-}"

SRC_DIR="$(pwd)"

SYSTEM_UPDATE_CONF_DIR="${SYSTEM_UPDATE_CONF_DIR:-${SYSCONFDIR}/jedi_system_update}"
START_UPDATE_COMMAND="${SBINDIR}/start_update.sh"
UPDATE_ROOTFS_SOURCE="/tmp/update_source"
TARGET_STORAGE_DEVICE=""

JEDI_PARTITION_TABLE_FILE_NAME="config/jedi_emmc_sfdisk.table"

STORAGE_DEVICE_IMG="storage_device.img"
BYTES_PER_SECTOR="512"
STORAGE_DEVICE_SIZE="7553024" # sectors, about 3.6 GiB

TEST_UPDATE_ROOTFS_FILE="test/test_rootfs.tar.xz"
TEMP_TEST_UPDATE_ROOTFS_FILE="rootfs-v1.2.3.tar.xz"

TEST_UPDATE_ROOTFS_FILE="${SRC_DIR}/test/test_rootfs.tar.xz"
TEST_OUTPUT_FILE="$(mktemp -d)/test_results_$(basename "${0%.sh}").txt"

NAME_TEMPLATE_TOOLBOX="um-update-toolbox"
NAME_TEMPLATE_UPDATEROOT="temp_update_mount"
NAME_TEMPLATE_WORKDIR="start_update_workdir"

toolbox_image=""
toolbox_root_dir=""
update_mount=""
work_dir=""

exit_on_failure=false
result=0

test_disk_integrity()
{
    # All return codes not 0 should be considered an error, since prepare_disk
    # should have fixed any potential filesystem error.
    sfdisk -Vl "${TARGET_STORAGE_DEVICE}"
    fsck.ext4 -fn "${TARGET_STORAGE_DEVICE}p1"
    fsck.f2fs "${TARGET_STORAGE_DEVICE}p2"
    fsck.f2fs "${TARGET_STORAGE_DEVICE}p3"
}

create_dummy_storage_device()
{
    echo "Creating test image: '${STORAGE_DEVICE_IMG}'."

    dd if="/dev/zero" of="${STORAGE_DEVICE_IMG}" bs="1" count="0" \
        seek="$((BYTES_PER_SECTOR * STORAGE_DEVICE_SIZE))"

    echo "writing partition table:"

    sfdisk "${STORAGE_DEVICE_IMG}" < "${SRC_DIR}/${JEDI_PARTITION_TABLE_FILE_NAME}"

    echo "formatting partitions"

    TARGET_STORAGE_DEVICE="$(losetup --show --find --partscan "${STORAGE_DEVICE_IMG}")"

    mkfs.ext4 -q "${TARGET_STORAGE_DEVICE}p1"
    mkfs.f2fs -q "${TARGET_STORAGE_DEVICE}p2"
    mkfs.f2fs -q "${TARGET_STORAGE_DEVICE}p3"

    test_disk_integrity

    echo "Successfully created dummy storage device: '${TARGET_STORAGE_DEVICE}'."
}

setup()
{
    toolbox_root_dir="$(mktemp -d -t "${NAME_TEMPLATE_TOOLBOX}.XXXXXX")"
    setup_chroot_env "${toolbox_image}" "${toolbox_root_dir}"

    mkdir -p "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}"
    tar -xJvf "${TEST_UPDATE_ROOTFS_FILE}" -C "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}" \
        > /dev/null 2> /dev/null

    update_mount="$(mktemp -d -t "${NAME_TEMPLATE_UPDATEROOT}.XXXXXX")"

    work_dir="$(mktemp -d -t "${NAME_TEMPLATE_WORKDIR}.XXXXXX")"
    cd "${work_dir}"

    create_dummy_storage_device
}

teardown()
{
    teardown_chroot_env "${toolbox_root_dir}"

    cd "${SRC_DIR}"

    if [ -b "${TARGET_STORAGE_DEVICE}" ]; then
        losetup -d "${TARGET_STORAGE_DEVICE}"
        TARGET_STORAGE_DEVICE=""
    fi

    if [ -d "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}" ] && \
       [ -z "${toolbox_root_dir##*${NAME_TEMPLATE_TOOLBOX}*}" ]; then
        rm -rf "${toolbox_root_dir:?}/${UPDATE_ROOTFS_SOURCE}"
    fi

    if [ -d "${toolbox_root_dir}" ] && [ -z "${toolbox_root_dir##*${NAME_TEMPLATE_TOOLBOX}*}" ]; then
        rm -rf "${toolbox_root_dir:?}"
    fi

    if [ -d "${update_mount}" ] && [ -z "${update_mount##*${NAME_TEMPLATE_UPDATEROOT}*}" ]; then
        rm -rf "${update_mount:?}"
    fi

    if [ -d "${work_dir}" ] && [ -z "${work_dir##*${NAME_TEMPLATE_WORKDIR}*}" ]; then
        rm -rf "${work_dir:?}"
    fi
}

failure_exit()
{
    echo "Test exit per request."
    echo "When finished, the following is needed to cleanup!"
    echo "  sudo sh -c '\\"
    echo "    losetup -d '${TARGET_STORAGE_DEVICE}' && \\"
    echo "    rm -rf '${work_dir}/*' && \\"

    failure_exit_chroot_env

    echo "  '"
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

test_rsync_ignore_file_not_found_nok()
{
    cp "${TEST_UPDATE_ROOTFS_FILE}" "${update_mount}/${TEMP_TEST_UPDATE_ROOTFS_FILE}"
    rm "${toolbox_root_dir:?}/${SYSTEM_UPDATE_CONF_DIR}/"*_exclude_list.txt
    "${toolbox_root_dir}/${START_UPDATE_COMMAND}" "${toolbox_root_dir}" "${update_mount}" "${TARGET_STORAGE_DEVICE}" || return 0
}

test_partition_table_not_found_nok()
{
    cp "${TEST_UPDATE_ROOTFS_FILE}" "${update_mount}/${TEMP_TEST_UPDATE_ROOTFS_FILE}"
    rm "${toolbox_root_dir:?}/${SYSTEM_UPDATE_CONF_DIR}/"*.table
    "${toolbox_root_dir}/${START_UPDATE_COMMAND}" "${toolbox_root_dir}" "${update_mount}" "${TARGET_STORAGE_DEVICE}" || return 0
}

test_update_rootfs_corrupt_nok()
{
    cp "${TEST_UPDATE_ROOTFS_FILE}" "${update_mount}/${TEMP_TEST_UPDATE_ROOTFS_FILE}"
    echo "Append this data to corrupt the archive" >> "${update_mount}/${TEMP_TEST_UPDATE_ROOTFS_FILE}"
    "${toolbox_root_dir}/${START_UPDATE_COMMAND}" "${toolbox_root_dir}" "${update_mount}" "${TARGET_STORAGE_DEVICE}" || return 0
}

test_multiple_update_rootfs_files_nok()
{
    cp "${TEST_UPDATE_ROOTFS_FILE}" "${update_mount}/${TEMP_TEST_UPDATE_ROOTFS_FILE}"
    cp "${update_mount}/${TEMP_TEST_UPDATE_ROOTFS_FILE}" \
        "${update_mount}/rootfs-v2.1.0.tar.xz"
    "${toolbox_root_dir}/${START_UPDATE_COMMAND}" "${toolbox_root_dir}" "${update_mount}" "${TARGET_STORAGE_DEVICE}" || return 0
}

test_successful_update_ok()
{
    # Note that with rsync --delete, we want to ensure both the '.keep' as
    # well as the '.discard' file are ignored.
    for exclude in "${SYSTEM_UPDATE_CONF_DIR}/"*".keep" \
                   "${SYSTEM_UPDATE_CONF_DIR}/"*".discard" \
                   "${UPDATE_ROOTFS_SOURCE}/${SYSTEM_UPDATE_CONF_DIR}"*".keep" \
                   "${UPDATE_ROOTFS_SOURCE}/${SYSTEM_UPDATE_CONF_DIR}"*".discard"; do
        exclude_list="${exclude_list:-} --exclude-from ${exclude}"
    done

    cp "${TEST_UPDATE_ROOTFS_FILE}" "${update_mount}/${TEMP_TEST_UPDATE_ROOTFS_FILE}"
    "${toolbox_root_dir}/${START_UPDATE_COMMAND}" "${toolbox_root_dir}" "${update_mount}" "${TARGET_STORAGE_DEVICE}" || return 1

    update_target="$(mktemp -d)"
    mount -t auto -v "${TARGET_STORAGE_DEVICE}p2" "${update_target}"

    rsync -a -c -x --dry-run \
        "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}/" "${update_target}/" \
        "${exclude_list}" || return 1

    umount "${update_target}"

    if [ -z "${update_target##*/tmp/*}" ]; then
        rm -rf "${update_target:?}"
    fi
}

usage()
{
    echo "Usage:   ${0} [OPTIONS] <toolbox image file>"
    echo "  -e   Stop consecutive tests on failure without cleanup"
    echo "  -h   Print usage"
    echo "NOTE: This script requires root permissions to run."
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
    echo "Missing argument <toolbox image file>."
    usage
    exit 1
fi

toolbox_image="${*}"

if [ ! -r "${toolbox_image}" ]; then
    echo "Given toolbox image '${toolbox_image}' not found."
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

run_test test_partition_table_not_found_nok
run_test test_rsync_ignore_file_not_found_nok
run_test test_update_rootfs_corrupt_nok
run_test test_multiple_update_rootfs_files_nok
run_test test_successful_update_ok

echo "________________________________________________________________________________"
echo "Test results '${TEST_OUTPUT_FILE}':"
echo
cat "${TEST_OUTPUT_FILE}"
echo "________________________________________________________________________________"

if [ "${result}" -ne 0 ]; then
   exit 1
fi

exit 0
