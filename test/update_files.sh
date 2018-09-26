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

# common directory variables
PREFIX="${PREFIX:-/usr/local}"
EXEC_PREFIX="${PREFIX}"
LIBEXECDIR="${EXEC_PREFIX}/libexec"
SYSCONFDIR="${SYSCONFDIR:-/etc}"

ARM_EMU_BIN="${ARM_EMU_BIN:-}"

SRC_DIR="$(pwd)"

SYSTEM_UPDATE_CONF_DIR="${SYSTEM_UPDATE_CONF_DIR:-${SYSCONFDIR}/jedi_system_update}"
SYSTEM_UPDATE_SCRIPT_DIR="${SYSTEM_UPDATE_SCRIPT_DIR:-${LIBEXECDIR}/jedi_system_update.d/}"
UPDATE_EXCLUDE_LIST_FILE="jedi_update_exclude_list.txt"
UPDATE_ROOTFS_SOURCE="/tmp/update_source"
TARGET_STORAGE_DEVICE=""

JEDI_PARTITION_TABLE_FILE_NAME="config/jedi_emmc_sfdisk.table"
UPDATE_FILES_COMMAND="${SYSTEM_UPDATE_SCRIPT_DIR}/50_update_files.sh"

ULTIMAKER_VERSION_FILE="${SYSCONFDIR}/ultimaker_version"
DEBIAN_VERSION_FILE="${SYSCONFDIR}/debian_version"

STORAGE_DEVICE_IMG="storage_device.img"
BYTES_PER_SECTOR="512"
STORAGE_DEVICE_SIZE="7553024" # sectors, about 3.6 GiB

TEST_UPDATE_ROOTFS_FILE="${SRC_DIR}/test/test_rootfs.tar.xz"
TEST_OUTPUT_FILE="$(mktemp -d)/test_results_$(basename "${0%.sh}").txt"

NAME_TEMPLATE_TOOLBOX="um-update-toolbox"
NAME_TEMPLATE_WORKDIR="update_files_workdir"

toolbox_image=""
toolbox_root_dir=""
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
    toolbox_root_dir="$(mktemp -d -t "${NAME_TEMPLATE_WORKDIR}.XXXXXX")"
    setup_chroot_env "${toolbox_image}" "${toolbox_root_dir}"

    mkdir -p "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}"
    tar -xJvf "${TEST_UPDATE_ROOTFS_FILE}" -C "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}" \
        > /dev/null 2> /dev/null

    work_dir="$(mktemp -d -t "${NAME_TEMPLATE_TOOLBOX}.XXXXXX")"
    cd "${work_dir}"

    create_dummy_storage_device
}

teardown()
{
    teardown_chroot_env "${toolbox_root_dir}"

    if [ -b "${TARGET_STORAGE_DEVICE}" ]; then
        losetup -d "${TARGET_STORAGE_DEVICE}"
        TARGET_STORAGE_DEVICE=""
    fi

    if [ -d "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}" ] && [ -z "${toolbox_root_dir##*${NAME_TEMPLATE_TOOLBOX}*}" ]; then
        rm -rf "${toolbox_root_dir:?}${UPDATE_ROOTFS_SOURCE}"
    fi

    cd "${SRC_DIR}"

    if [ -d "${work_dir}" ] && [ -z "${work_dir##*${NAME_TEMPLATE_WORKDIR}*}" ]; then
        rm -r "${work_dir}"
    fi

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

test_missing_argument_update_rootfs_source_nok()
{
    eval chroot "${toolbox_root_dir}" "${UPDATE_FILES_COMMAND}" -s '' -d "${TARGET_STORAGE_DEVICE}" || return 0
}

test_update_rootfs_source_not_a_directory_nok()
{
    chroot_environment=" \
        UPDATE_ROOTFS_SOURCE=/tmp/not_existing_dir \
        TARGET_STORAGE_DEVICE=${TARGET_STORAGE_DEVICE} \
    "

    eval "${chroot_environment}" chroot "${toolbox_root_dir}" /bin/sh -c "${chroot_environment} ${UPDATE_FILES_COMMAND}" || return 0
}

test_invalid_block_device_nok()
{
    target_device="/dev/loop100"

    eval chroot "${toolbox_root_dir}" "${UPDATE_FILES_COMMAND}" -s "${UPDATE_ROOTFS_SOURCE}" -d "${target_device}" || return 0
}

test_no_debian_distribution_found_nok()
{
    chroot_environment=" \
        TARGET_STORAGE_DEVICE=${TARGET_STORAGE_DEVICE} \
        UPDATE_ROOTFS_SOURCE=${UPDATE_ROOTFS_SOURCE} \
    "

    unlink "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}/${DEBIAN_VERSION_FILE}"

    eval "${chroot_environment}" chroot "${toolbox_root_dir}" "${UPDATE_FILES_COMMAND}" || return 0
}

test_no_ultimaker_software_found_nok()
{
    chroot_environment=" \
        TARGET_STORAGE_DEVICE=${TARGET_STORAGE_DEVICE} \
        UPDATE_ROOTFS_SOURCE=${UPDATE_ROOTFS_SOURCE} \
    "

    unlink "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}/${ULTIMAKER_VERSION_FILE}"

    eval "${chroot_environment}" chroot "${toolbox_root_dir}" "${UPDATE_FILES_COMMAND}" || return 0
}

test_update_files_ok()
{
    chroot_environment=" \
        TARGET_STORAGE_DEVICE=${TARGET_STORAGE_DEVICE} \
        UPDATE_ROOTFS_SOURCE=${UPDATE_ROOTFS_SOURCE} \
    "

    eval "${chroot_environment}" chroot "${toolbox_root_dir}" "${UPDATE_FILES_COMMAND}" || return 1

    update_target="$(mktemp -d -t "tmp_update_target.XXXXXX")"
    mount -t auto -v "${TARGET_STORAGE_DEVICE}p2" "${update_target}" || return 1

    rsync --exclude-from "${SRC_DIR}/config/${UPDATE_EXCLUDE_LIST_FILE}" -c -a -x --dry-run \
        "${toolbox_root_dir}/${UPDATE_ROOTFS_SOURCE}/" "${update_target}/" || return 1

    umount "${update_target}"

    if [ -z "${update_target##*tmp_update_target*}" ]; then
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

run_test test_missing_argument_update_rootfs_source_nok
run_test test_update_rootfs_source_not_a_directory_nok
run_test test_invalid_block_device_nok
run_test test_no_debian_distribution_found_nok
run_test test_no_ultimaker_software_found_nok
run_test test_update_files_ok

echo "________________________________________________________________________________"
echo "Test results '${TEST_OUTPUT_FILE}':"
echo
cat "${TEST_OUTPUT_FILE}"
echo "________________________________________________________________________________"

if [ "${result}" -ne 0 ]; then
   exit 1
fi

exit 0
