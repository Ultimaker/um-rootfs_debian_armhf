#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

ARM_EMU_BIN="${ARM_EMU_BIN:-}"

SYSTEM_UPDATE_DIR="/etc/system_update"
SYSTEM_UPDATE_ENTRYPOINT="start_update.sh"
PREPARE_DISK_COMMAND="${SYSTEM_UPDATE_DIR}.d/30_prepare_disk.sh"
JEDI_PARTITION_TABLE_FILE_NAME="${SYSTEM_UPDATE_DIR}/jedi_emmc_sfdisk.table"
UPDATE_FILES_COMMAND="${SYSTEM_UPDATE_DIR}.d/50_update_files.sh"

# Test storage device parameters.
# All storage start and and parameters are sector numbers. actual byte positions
# are calculated by multiplying the sector number with the sector size.
STORAGE_DEVICE_IMG="/tmp/storage_device.img"
BYTES_PER_SECTOR="512"
MIN_PARTITION_SIZE="78124"    # 40 MiB (enough for f2fs and ext4)
STORAGE_DEVICE_SIZE="7553024" # sectors, about 3.6 GiB
#BOOT_START="2048"             # offset 1 MiB
ROOTFS_START="67584"          # offset 33 MiB
USERDATA_START="1998848"      # offset 976 MiB
LOOP_STORAGE_DEVICE=""

PARTITION_TABLE_FILE_NAME="partition_table"
PARTITION_TABLE_FILE="${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE_NAME}"
TMP_TEST_IMAGE_FILE="/tmp/test_file.img"
UPDATE_SOURCE="/tmp/update_source"
UPDATE_EXCLUDE_LIST_FILE="config/jedi_update_exclude_list.txt"
TEST_UPDATE_ROOTFS_FILE="test/test_rootfs.tar.xz"

overlayfs_dir=""
rootfs_dir=""

result=0

is_dev_setup_mounted=false
exit_on_failure=false


random_int_within()
{
    shuf -n 1 -i "${1}"-"${2}"
}

random_int()
{
    shuf -n 1 -i 0-"${1}"
    random_int_within "0" "${1}"
}

execute_prepare_disk()
{
    # sha512sum is executed in the chroot environment to avoid that rootfs dir is prefixed to the file path.
    chroot "${rootfs_dir}" sha512sum "${PARTITION_TABLE_FILE}" > "${rootfs_dir}${PARTITION_TABLE_FILE}.sha512" || return 1
    chroot "${rootfs_dir}" "${PREPARE_DISK_COMMAND}" -t "${PARTITION_TABLE_FILE_NAME}" -d "${LOOP_STORAGE_DEVICE}" || return 1

    sfdisk -d "${LOOP_STORAGE_DEVICE}" > "${rootfs_dir}${PARTITION_TABLE_FILE}.verify"

    # Remove the identifiers in the header because they will always change.
    sed -i "s/label-id:.*//" "${rootfs_dir}${PARTITION_TABLE_FILE}"
    sed -i "s/label-id:.*//" "${rootfs_dir}${PARTITION_TABLE_FILE}.verify"
    # Remove the name from the source partition file, as the names are not stored in the partition table.
    sed -i "s/, name=[a-z]+//" "${rootfs_dir}${PARTITION_TABLE_FILE}"

    diff -b "${rootfs_dir}${PARTITION_TABLE_FILE}" "${rootfs_dir}${PARTITION_TABLE_FILE}.verify" || return 1
}

test_disk_integrity()
{
    # All return codes not 0 should be considered an error, since prepare_disk
    # should have fixed any potential filesystem error.
    sfdisk -Vl "${LOOP_STORAGE_DEVICE}" || return 1
    fsck.ext4 -fn "${LOOP_STORAGE_DEVICE}p1" || return 1
    fsck.f2fs "${LOOP_STORAGE_DEVICE}p2" || return 1
    fsck.f2fs "${LOOP_STORAGE_DEVICE}p3" || return 1
}

create_dummy_storage_device()
{
    echo "Creating test image: '${rootfs_dir}${STORAGE_DEVICE_IMG}'."
    dd if="/dev/zero" of="${rootfs_dir}${STORAGE_DEVICE_IMG}" bs="1" count="0" \
        seek="$((BYTES_PER_SECTOR * STORAGE_DEVICE_SIZE))"

    echo "writing partition table:"

    sfdisk "${rootfs_dir}${STORAGE_DEVICE_IMG}" < "${rootfs_dir}${JEDI_PARTITION_TABLE_FILE_NAME}"

    echo "formatting partitions"

    LOOP_STORAGE_DEVICE="$(losetup --show --find --partscan "${rootfs_dir}${STORAGE_DEVICE_IMG}")"

    mkfs.ext4 -q "${LOOP_STORAGE_DEVICE}p1"
    mkfs.f2fs -q "${LOOP_STORAGE_DEVICE}p2"
    mkfs.f2fs -q "${LOOP_STORAGE_DEVICE}p3"

    if ! test_disk_integrity; then
        echo "Unrecoverable error creating dummy storage device: '${LOOP_STORAGE_DEVICE}'."
        exit 1
    fi

    echo "Successfully created dummy storage device: '${LOOP_STORAGE_DEVICE}'."
}

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

    mkdir -p "${rootfs_dir}${UPDATE_SOURCE}"
    tar xvfJ "${TEST_UPDATE_ROOTFS_FILE}" -C "${rootfs_dir}${UPDATE_SOURCE}" \
        > /dev/null 2> /dev/null

    touch "${rootfs_dir}/${ARM_EMU_BIN}"
    mount --bind -o ro "${ARM_EMU_BIN}" "${rootfs_dir}/${ARM_EMU_BIN}"

    mount --bind /proc "${rootfs_dir}/proc" 1> /dev/null
    ln -s ../proc/self/mounts "${rootfs_dir}/etc/mtab"

    if ! grep -qE "/dev.*devtmpfs" /proc/mounts; then
        mount -t devtmpfs none "/dev"
        is_dev_setup_mounted=true
    fi

    mount -t devtmpfs none "${rootfs_dir}/dev"

    dd if=/dev/zero of="${rootfs_dir}/${TMP_TEST_IMAGE_FILE}" bs=1 count=0 seek=128M 2> /dev/null

    create_dummy_storage_device

    sfdisk -d "${LOOP_STORAGE_DEVICE}" > "${rootfs_dir}${PARTITION_TABLE_FILE}"
}

teardown()
{
    mounts="${rootfs_dir} ${overlayfs_dir}/rom ${overlayfs_dir}"

    if [ ! -d "${rootfs_dir}" ]; then
        return
    fi

    for partition_table_file in "${rootfs_dir}${PARTITION_TABLE_FILE}"*; do
        unlink "${partition_table_file}"
    done

    if [ -d "${rootfs_dir}${UPDATE_SOURCE}" ]; then
        rm -rf "${rootfs_dir}${UPDATE_SOURCE}"
    fi

    if [ -b "${LOOP_STORAGE_DEVICE}" ]; then
        losetup -d "${LOOP_STORAGE_DEVICE}"
    fi

    if [ -f "${rootfs_dir}${STORAGE_DEVICE_IMG}" ]; then
        unlink "${rootfs_dir}${STORAGE_DEVICE_IMG}"
    fi

    if [ -e "${rootfs_dir}/${ARM_EMU_BIN}" ]; then
        if grep -q "$(realpath "${rootfs_dir}/${ARM_EMU_BIN}")" "/proc/mounts"; then
            umount "${rootfs_dir}/${ARM_EMU_BIN}" || result=1
        fi
        if [ -f "${rootfs_dir}/${ARM_EMU_BIN}" ]; then
            unlink "${rootfs_dir}/${ARM_EMU_BIN}" || result=1
        fi
    fi

    if grep -q "${rootfs_dir}/dev" /proc/mounts; then
        umount "${rootfs_dir}/dev" || result=1
    fi

    if "${is_dev_setup_mounted}"; then
        umount "/dev" || result=1
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
    echo "    losetup -d '${LOOP_STORAGE_DEVICE}' && \\"
    echo "    unlink '${STORAGE_DEVICE_IMG}' && \\"
    echo "    umount '${rootfs_dir}/dev' && \\"
    echo "    if '${is_dev_setup_mounted}'; then \\"
    echo "      umount '/dev' \\"
    echo "    fi && \\"
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
    else
        echo "Result - ERROR"
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
    chroot "${rootfs_dir}" /bin/busybox true
}

test_execute_sha512()
{
    chroot "${rootfs_dir}" sha512sum /bin/busybox > "${rootfs_dir}${TMP_TEST_IMAGE_FILE}"
    chroot "${rootfs_dir}" sha512sum -csw "${TMP_TEST_IMAGE_FILE}"
}

test_execute_sfdisk()
{
    chroot "${rootfs_dir}" /sbin/sfdisk -l "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
}

test_execute_mkfs_ext4()
{
    chroot "${rootfs_dir}" /sbin/mkfs.ext4 "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
    chroot "${rootfs_dir}" /sbin/fsck.ext4 -fn "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
}

test_execute_resize2fs()
{
    test_execute_mkfs_ext4
    chroot "${rootfs_dir}" /usr/sbin/resize2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
    chroot "${rootfs_dir}" /sbin/fsck.ext4 -fn "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
}

test_execute_mkfs_f2fs()
{
    chroot "${rootfs_dir}" /usr/sbin/mkfs.f2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
    chroot "${rootfs_dir}" /usr/sbin/fsck.f2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
}

test_execute_resizef2fs()
{
    test_execute_mkfs_f2fs
    chroot "${rootfs_dir}" /usr/sbin/resize.f2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
    chroot "${rootfs_dir}" /usr/sbin/fsck.f2fs "${TMP_TEST_IMAGE_FILE}" 1> /dev/null
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
    test -x "${rootfs_dir}/sbin/${SYSTEM_UPDATE_ENTRYPOINT}" || return 1
}

test_jedi_exclude_list_exists()
{
    update_exclude_list_file="jedi_update_exclude_list.txt"
    test -f "${rootfs_dir}${SYSTEM_UPDATE_DIR}/${update_exclude_list_file}" || return 1
}

test_jedi_partition_table_file_exists()
{
    jedi_partition_table_file="jedi_emmc_sfdisk.table"
    test -f "${rootfs_dir}${SYSTEM_UPDATE_DIR}/${jedi_partition_table_file}" || return 1
}

test_execute_disk_prepare_sha512_nok()
{
    chroot "${rootfs_dir}" sha512sum "${PARTITION_TABLE_FILE}" > "${rootfs_dir}${PARTITION_TABLE_FILE}.sha512"
    echo "corrupted partition table data" >> "${rootfs_dir}${PARTITION_TABLE_FILE}"
    chroot "${rootfs_dir}" "${PREPARE_DISK_COMMAND}" -t "${PARTITION_TABLE_FILE_NAME}" -d "${LOOP_STORAGE_DEVICE}" || return 0
}

test_execute_disk_prepare_with_arguments_from_environment_ok()
{
    chroot "${rootfs_dir}" sha512sum "${PARTITION_TABLE_FILE}" > "${rootfs_dir}${PARTITION_TABLE_FILE}.sha512"
    chroot "${rootfs_dir}" /bin/sh -c \
        "PARTITION_TABLE_FILE=${PARTITION_TABLE_FILE_NAME} TARGET_STORAGE_DEVICE=${LOOP_STORAGE_DEVICE} ${PREPARE_DISK_COMMAND}" \
            || return 1
}

test_execute_resize_partition_grow_rootfs_ok()
{
    max_userdata_size="$((STORAGE_DEVICE_SIZE - USERDATA_START))"
    new_userdata_size="$(random_int_within "${MIN_PARTITION_SIZE}" "${max_userdata_size}")"

    new_userdata_start="$((STORAGE_DEVICE_SIZE - new_userdata_size))"
    new_rootfs_size="$((new_userdata_start - ROOTFS_START))"

    # In every line in the partition table look for a string "p3<don't care>type" and replace it with
    # with new the new disk partition parameters defined above.
    sed -i "s|${LOOP_STORAGE_DEVICE}p2.*type|${LOOP_STORAGE_DEVICE}p2 : start= ${ROOTFS_START}, size= ${new_rootfs_size}, type|" "${rootfs_dir}${PARTITION_TABLE_FILE}"
    sed -i "s|${LOOP_STORAGE_DEVICE}p3.*type|${LOOP_STORAGE_DEVICE}p3 : start= ${new_userdata_start}, size= ${new_userdata_size}, type|" "${rootfs_dir}${PARTITION_TABLE_FILE}"

    execute_prepare_disk || return 1
    test_disk_integrity || return 1
}

test_execute_disk_prepare_resize_not_needed_ok()
{
    execute_prepare_disk || return 1
    test_disk_integrity || return 1
}

test_execute_update_no_update_source_option_passed_nok()
{
    chroot "${rootfs_dir}" "${UPDATE_FILES_COMMAND}" -s "" -d "${LOOP_STORAGE_DEVICE}p2" || return 0
}

test_execute_update_invalid_block_device_nok()
{
    target_device="/dev/loop100"
    chroot "${rootfs_dir}" "${UPDATE_FILES_COMMAND}" -s "${UPDATE_SOURCE}" -d "${target_device}" || return 0
}

test_execute_update_target_device_ok()
{
    chroot "${rootfs_dir}" "${UPDATE_FILES_COMMAND}" -s "${UPDATE_SOURCE}" -d "${LOOP_STORAGE_DEVICE}" || return 1

    update_target="$(mktemp -d)"
    mount -t auto -v "${LOOP_STORAGE_DEVICE}p2" "${update_target}" || return 1

    rsync --exclude-from "${UPDATE_EXCLUDE_LIST_FILE}" -c -a -x --dry-run \
        "${rootfs_dir}${UPDATE_SOURCE}/" "${update_target}/" || return 1

    umount "${update_target}"

    if [ -z "${update_target##*/tmp/*}" ]; then
        rm -rf "${update_target}"
    fi
}

usage()
{
cat <<-EOT
	Usage:   "${0}" [OPTIONS] <file.img>
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

trap cleanup EXIT

echo "Running tests on '${ROOTFS_IMG}'."
run_test test_execute_busybox
run_test test_execute_sha512
run_test test_execute_sfdisk
run_test test_execute_mkfs_ext4
run_test test_execute_resize2fs
run_test test_execute_mkfs_f2fs
run_test test_execute_resizef2fs
run_test test_execute_mount
run_test test_execute_rsync
run_test test_system_update_entrypoint
run_test test_jedi_exclude_list_exists
run_test test_jedi_partition_table_file_exists
run_test test_execute_disk_prepare_sha512_nok
run_test test_execute_disk_prepare_with_arguments_from_environment_ok
run_test test_execute_resize_partition_grow_rootfs_ok
run_test test_execute_disk_prepare_resize_not_needed_ok
run_test test_execute_update_no_update_source_option_passed_nok
run_test test_execute_update_invalid_block_device_nok
run_test test_execute_update_target_device_ok


if [ "${result}" -ne 0 ]; then
   echo "ERROR: There where failures testing '${ROOTFS_IMG}'."
   exit 1
fi

echo "All Ok"

exit 0
