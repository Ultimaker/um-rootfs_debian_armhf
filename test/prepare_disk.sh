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

ARM_EMU_BIN="${ARM_EMU_BIN:-}"

CWD="$(pwd)"

SYSTEM_UPDATE_DIR="${SYSTEM_UPDATE_DIR:-/etc/system_update}"
PARTITION_TABLE_FILE="test_jedi_emmc_sfdisk.table"
TARGET_STORAGE_DEVICE=""

JEDI_PARTITION_TABLE_FILE_NAME="config/jedi_emmc_sfdisk.table"
PREPARE_DISK_COMMAND="/etc/system_update.d/30_prepare_disk.sh"

STORAGE_DEVICE_IMG="storage_device.img"
BYTES_PER_SECTOR="512"
STORAGE_DEVICE_SIZE="7553024" # sectors, about 3.6 GiB

TEST_OUTPUT_FILE="$(mktemp -d)/test_results_$(basename "${0%.sh}").txt"

NAME_TEMPLATE_TOOLBOX="um-update-toolbox"
NAME_TEMPLATE_WORKDIR="update_files_workdir"

toolbox_image=""
toolbox_root_dir=""
work_dir=""

exit_on_failure=false
result=0


execute_prepare_disk()
{
    chroot_environment="SYSTEM_UPDATE_DIR=${SYSTEM_UPDATE_DIR}"
    chroot_environment="${chroot_environment} PARTITION_TABLE_FILE=${PARTITION_TABLE_FILE}"
    chroot_environment="${chroot_environment} TARGET_STORAGE_DEVICE=${TARGET_STORAGE_DEVICE}"

    sha512sum "${PARTITION_TABLE_FILE}" > "${PARTITION_TABLE_FILE}.sha512"
    cp "${PARTITION_TABLE_FILE}" "${toolbox_root_dir}${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}"
    cp "${PARTITION_TABLE_FILE}.sha512" "${toolbox_root_dir}${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}.sha512"

    chroot "${toolbox_root_dir}" /bin/sh -c "${chroot_environment} ${PREPARE_DISK_COMMAND}" || return 1

    sfdisk -d "${TARGET_STORAGE_DEVICE}" > "${PARTITION_TABLE_FILE}.verify"

    # Remove the identifiers in the header because they will always change.
    sed -i "s/label-id:.*//" "${PARTITION_TABLE_FILE}"
    sed -i "s/label-id:.*//" "${PARTITION_TABLE_FILE}.verify"

    # Remove the name from the source partition file, as the names are not stored in the partition table.
    sed -i "s/, name=.*//" "${PARTITION_TABLE_FILE}"

    diff -b "${PARTITION_TABLE_FILE}" "${PARTITION_TABLE_FILE}.verify" || return 1
}

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

    sfdisk "${STORAGE_DEVICE_IMG}" < "${CWD}/${JEDI_PARTITION_TABLE_FILE_NAME}"

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
    toolbox_root_dir="$(mktemp -d -t "${NAME_TEMPLATE_TOOLBOX}.XXXXXXX")"

    setup_chroot_env "${toolbox_image}" "${toolbox_root_dir}"

    work_dir="$(mktemp -d -t "${NAME_TEMPLATE_WORKDIR}.XXXXXXX")"
    cd "${work_dir}"

    create_dummy_storage_device

    sfdisk -d "${TARGET_STORAGE_DEVICE}" > "${PARTITION_TABLE_FILE}"

    # add the partition labels to the partition file, they will be used as label
    sed -i "s|${TARGET_STORAGE_DEVICE}p1.*|&, name=boot|" "${PARTITION_TABLE_FILE}"
    sed -i "s|${TARGET_STORAGE_DEVICE}p2.*|&, name=root|" "${PARTITION_TABLE_FILE}"
    sed -i "s|${TARGET_STORAGE_DEVICE}p3.*|&, name=user|" "${PARTITION_TABLE_FILE}"
}

teardown()
{
    if [ -b "${TARGET_STORAGE_DEVICE}" ]; then
        losetup -d "${TARGET_STORAGE_DEVICE}"
        TARGET_STORAGE_DEVICE=""
    fi

    cd "${CWD}"

    if [ -d "${work_dir}" ] && [ -z "${work_dir##*${NAME_TEMPLATE_TOOLBOX}*}" ]; then
        rm -r "${work_dir}"
    fi

    teardown_chroot_env "${toolbox_root_dir}"

    if [ -d "${toolbox_root_dir}" ] && [ -z "${toolbox_root_dir##*${NAME_TEMPLATE_TOOLBOX}*}" ]; then
        rm -r "${toolbox_root_dir}"
    fi
}

failure_exit()
{
    echo "Test exit per request."
    echo "When finished, the following is needed to cleanup!"
    echo "  sudo sh -c '\\"
    echo "    losetup -d '${TARGET_STORAGE_DEVICE}' && \\"
    echo "    rm -rf '${work_dir:?}/*' && \\"

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


test_something_ok()
{
    execute_prepare_disk
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

run_test test_something_ok

echo "________________________________________________________________________________"
echo "Test results '${TEST_OUTPUT_FILE}':"
echo
cat "${TEST_OUTPUT_FILE}"
echo "________________________________________________________________________________"

if [ "${result}" -ne 0 ]; then
   exit 1
fi

exit 0
