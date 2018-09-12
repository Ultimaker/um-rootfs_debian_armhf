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
MIN_PARTITION_SIZE="78124"    # 40 MiB (enough for f2fs and ext4)
BYTES_PER_SECTOR="512"
STORAGE_DEVICE_SIZE="7553024" # sectors, about 3.6 GiB
BOOT_START="2048"             # offset 1 MiB
ROOTFS_START="67584"          # offset 33 MiB
USERDATA_START="1998848"      # offset 976 MiB

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

    eval "${chroot_environment}" chroot "${toolbox_root_dir}" "${PREPARE_DISK_COMMAND}" || return 1

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
    teardown_chroot_env "${toolbox_root_dir}"

    if [ -b "${TARGET_STORAGE_DEVICE}" ]; then
        losetup -d "${TARGET_STORAGE_DEVICE}"
        TARGET_STORAGE_DEVICE=""
    fi

    cd "${CWD}"

    if [ -d "${work_dir}" ] && [ -z "${work_dir##*${NAME_TEMPLATE_TOOLBOX}*}" ]; then
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

random_int_within()
{
    shuf -n 1 -i "${1}"-"${2}"
}

random_int()
{
    random_int_within "0" "${1}"
}

test_sha512_nok()
{
    sha512sum "${PARTITION_TABLE_FILE}" > "${PARTITION_TABLE_FILE}.sha512"
    echo "corrupted partition table data" >> "${PARTITION_TABLE_FILE}"
    execute_prepare_disk || return 0
}

test_grow_boot_ok()
{
    max_rootfs_size="$((USERDATA_START - ROOTFS_START))"
    new_rootfs_size="$(random_int_within "${MIN_PARTITION_SIZE}" "${max_rootfs_size}")"

    new_rootfs_start="$((USERDATA_START - new_rootfs_size))"
    new_boot_size="$((new_rootfs_start - BOOT_START))"

    # In every line in the partition table look for a string "p1<don't care>type" and replace it with
    # with new the new disk partition parameters defined above.
    sed -i "s|${TARGET_STORAGE_DEVICE}p1.*type|${TARGET_STORAGE_DEVICE}p1 : start= ${BOOT_START}, size= ${new_boot_size}, type|" "${PARTITION_TABLE_FILE}"
    sed -i "s|${TARGET_STORAGE_DEVICE}p2.*type|${TARGET_STORAGE_DEVICE}p2 : start= ${new_rootfs_start}, size= ${new_rootfs_size}, type|" "${PARTITION_TABLE_FILE}"

    execute_prepare_disk || return 1
    test_disk_integrity || return 1
}

test_grow_rootfs_ok()
{
    max_userdata_size="$((STORAGE_DEVICE_SIZE - USERDATA_START))"
    new_userdata_size="$(random_int_within "${MIN_PARTITION_SIZE}" "${max_userdata_size}")"

    new_userdata_start="$((STORAGE_DEVICE_SIZE - new_userdata_size))"
    new_rootfs_size="$((new_userdata_start - ROOTFS_START))"

    # In every line in the partition table look for a string "p3<don't care>type" and replace it with
    # with new the new disk partition parameters defined above.
    sed -i "s|${TARGET_STORAGE_DEVICE}p2.*type|${TARGET_STORAGE_DEVICE}p2 : start= ${ROOTFS_START}, size= ${new_rootfs_size}, type|" "${PARTITION_TABLE_FILE}"
    sed -i "s|${TARGET_STORAGE_DEVICE}p3.*type|${TARGET_STORAGE_DEVICE}p3 : start= ${new_userdata_start}, size= ${new_userdata_size}, type|" "${PARTITION_TABLE_FILE}"

    execute_prepare_disk || return 1
    test_disk_integrity || return 1
}

test_resize_not_needed_ok()
{
    execute_prepare_disk || return 1
    test_disk_integrity || return 1
}

test_grow_boot_overlapping_rootfs_nok()
{
    # Get a size between the current size and current + rootfs size
    rootfs_size="$((USERDATA_START - ROOTFS_START))"
    random_size="$(random_int "${rootfs_size}")"
    boot_size="$((ROOTFS_START - BOOT_START))"
    new_boot_size="$((boot_size + random_size + 1))"

    # In every line in the partition table look for a string "p1<don't care>type" and replace it with
    # with new the new disk partition parameters defined above.
    sed -i "s|${TARGET_STORAGE_DEVICE}p2.*type|${TARGET_STORAGE_DEVICE}p1 : start= ${BOOT_START}, size= ${new_boot_size}, type|" "${PARTITION_TABLE_FILE}"

    execute_prepare_disk || return 0
}

test_grow_rootfs_overlapping_userdata_nok()
{
    # Get a size between the current size and current + userdata size
    userdata_size="$((STORAGE_DEVICE_SIZE - USERDATA_START))"
    random_size="$(random_int "${userdata_size}")"
    boot_size="$((ROOTFS_START - BOOT_START))"
    new_rootfs_size="$((boot_size + random_size + 1))"

    # In every line in the partition table look for a string "p2<don't care>type" and replace it with
    # with new the new disk partition parameters defined above.
    sed -i "s|${TARGET_STORAGE_DEVICE}p2.*type|${TARGET_STORAGE_DEVICE}p2 : start= ${ROOTFS_START}, size= ${new_rootfs_size}, type|" "${PARTITION_TABLE_FILE}"

    execute_prepare_disk || return 0
}

test_grow_boot_invalid_start_nok()
{
    new_boot_start="$(random_int "$((BOOT_START -1))")"
    new_boot_size="$((ROOTFS_START - new_boot_start))"

    # In every line in the partition table look for a string "p1<don't care>type" and replace it with
    # with new the new disk partition parameters defined above.
    sed -i "s|${TARGET_STORAGE_DEVICE}p1.*type|${TARGET_STORAGE_DEVICE}p1 : start= ${new_boot_start}, size= ${new_boot_size}, type|" "${PARTITION_TABLE_FILE}"

    execute_prepare_disk || return 0
}


test_grow_beyond_disk_end_nok()
{
    new_userdata_size="$((STORAGE_DEVICE_END - ROOTFS_START))"

    # In every line in the partition table look for a string "p3<don't care>type" and replace it with
    # with new the new disk partition parameters defined above.
    sed -i "s|${TARGET_STORAGE_DEVICE}p3.*type|${TARGET_STORAGE_DEVICE}p3 : start= ${USERDATA_START}, size= ${new_userdata_size}, type|" "${PARTITION_TABLE_FILE}"

    execute_prepare_disk || return 0
}

test_corrupted_ext4_primary_superblock_ok()
{
    checksum_size="4"
    block_size="1024"
    primary_superblock_start="1"
    write_start_offset="$((primary_superblock_start * block_size + checksum_size))"
    dd if=/dev/zero of="${TARGET_STORAGE_DEVICE}p1" bs=1 count=10 seek="${write_start_offset}"

    test_grow_boot_ok || return 1
}

test_corrupted_f2fs_primary_superblock_ok()
{
    # f2fs superblock are located in the beginning of the filesystem, destroy primary
    f2fs_superblock_size="$((BYTES_PER_SECTOR * 10))"
    dd if=/dev/urandom of="${TARGET_STORAGE_DEVICE}p2" bs=1 count="$((f2fs_superblock_size / 2))"

    test_grow_rootfs_ok || return 1
}

test_corrupted_f2fs_superblocks_ok()
{
    # f2fs superblock are located in the beginning of the filesystem, destroy the primary and secondary
    f2fs_superblock_size="$((BYTES_PER_SECTOR * 10))"
    dd if=/dev/urandom of="${TARGET_STORAGE_DEVICE}p3" bs=1 count="$((f2fs_superblock_size + 1024))"

    test_grow_rootfs_ok || return 1
}

test_partition_table_file_does_not_exist_nok()
{
    chroot_environment="TARGET_STORAGE_DEVICE=${TARGET_STORAGE_DEVICE}"

    eval "${chroot_environment}" chroot "${toolbox_root_dir}" "${PREPARE_DISK_COMMAND}" || return 0
}

test_partition_table_file_does_not_exist_in_given_system_update_dir_nok()
{
    chroot_environment="TARGET_STORAGE_DEVICE=${TARGET_STORAGE_DEVICE}"
    chroot_environment="${chroot_environment} SYSTEM_UPDATE_DIR=/etc"

    eval "${chroot_environment}" chroot "${toolbox_root_dir}" "${PREPARE_DISK_COMMAND}" || return 0
}

test_target_storage_device_argument_not_provided_nok()
{
    eval chroot "${toolbox_root_dir}" "${PREPARE_DISK_COMMAND}" || return 0
}

test_target_storage_device_is_not_a_block_device_nok()
{
    chroot_environment="TARGET_STORAGE_DEVICE=/dev/tty1"

    eval "${chroot_environment}" chroot "${toolbox_root_dir}" "${PREPARE_DISK_COMMAND}" || return 0
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

run_test test_sha512_nok
run_test test_grow_boot_ok
run_test test_grow_rootfs_ok
run_test test_resize_not_needed_ok
run_test test_grow_boot_overlapping_rootfs_nok
run_test test_grow_rootfs_overlapping_userdata_nok
run_test test_grow_boot_invalid_start_nok
run_test test_grow_beyond_disk_end_nok
run_test test_corrupted_ext4_primary_superblock_ok
run_test test_corrupted_f2fs_primary_superblock_ok
run_test test_corrupted_f2fs_superblocks_ok
run_test test_partition_table_file_does_not_exist_nok
run_test test_partition_table_file_does_not_exist_in_given_system_update_dir_nok
run_test test_target_storage_device_is_not_a_block_device_nok
run_test test_target_storage_device_argument_not_provided_nok


echo "________________________________________________________________________________"
echo "Test results '${TEST_OUTPUT_FILE}':"
echo
cat "${TEST_OUTPUT_FILE}"
echo "________________________________________________________________________________"

if [ "${result}" -ne 0 ]; then
   exit 1
fi

exit 0
