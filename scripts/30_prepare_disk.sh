#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

# system_update wide configuration settings with default values
SYSTEM_UPDATE_DIR="${SYSTEM_UPDATE_DIR:-/etc/system_update}"
PARTITION_TABLE_FILE="${PARTITION_TABLE_FILE:-jedi_emmc_sfdisk.table}"
TARGET_STORAGE_DEVICE="${TARGET_STORAGE_DEVICE:-}"
# end system_update wide configuration settings

BOOT_PARTITION_START="2048"

usage()
{
    echo "Usage: ${0} [OPTIONS]"
    echo "Prepare the target TARGET_STORAGE_DEVICE to a predefined disk layout."
    echo "  -d <TARGET_STORAGE_DEVICE>, the target storage device for the update"
    echo "  -h Print this help text and exit"
    echo "  -t <PARTITION_TABLE_FILE>, Partition table file"
    echo "NOTE: This script is destructive and will destroy your data."
    echo "Note: the PARTITION_TABLE_FILE and TARGET_STORAGE_DEVICE arguments can also be passed by"
    echo "adding them to the scripts runtime environment."
}

is_integer()
{
    test "${1}" -eq "${1}" 2> /dev/null
}

is_comment()
{
    test -z "${1%%#*}"
}

# Returns 0 when resize is needed and 1 if not needed.
is_resize_needed()
{
    current_partition_table_file="$(mktemp)"
    sfdisk -d "${TARGET_STORAGE_DEVICE}" > "${current_partition_table_file}" || return 0
    resize_needed=false

    while IFS="${IFS}:=," read -r table_device _ table_start _ table_size _ _ _ table_name _; do
        if is_comment "${table_device}" || ! is_integer "${table_start}" || \
            ! is_integer "${table_size}"; then
            continue
        fi

        while IFS="${IFS}:=," read -r disk_device _ disk_start _ disk_size _; do
            if is_comment "${disk_device}" || ! is_integer "${disk_start}" || \
                ! is_integer "${disk_size}"; then
                continue
            fi

            if [ "${table_device}" != "${disk_device}" ]; then
                continue
            fi

            if [ "${table_start}" -ne "${disk_start}" ] || \
               [ "${table_size}" -ne "${disk_size}" ]; then
                resize_needed=true
                break 2
            fi
        done < "${current_partition_table_file}"
    done < "${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}"

    unlink "${current_partition_table_file}" || return 1

    if [ "${resize_needed}" = "true" ]; then
        return 0
    fi

    return 1
}

partition_sync()
{
    i=10
    while [ "${i}" -gt 0 ]; do
        if partprobe "${TARGET_STORAGE_DEVICE}"; then
            return
        fi

        echo "Partprobe failed, retrying."
        sleep 1

        i=$((i - 1))
    done

    echo "Partprobe failed, giving up."

    return 1
}

partitions_format()
{
    # Parse the output of sfdisk and temporally expand the Input Field Separator
    # with ':=,' and treat them as whitespaces, in other words, ignore them.
    sfdisk --quiet --dump "${TARGET_STORAGE_DEVICE}" | \
    while IFS="${IFS}:=," read -r disk_device _ disk_start _ disk_size _; do
        while IFS="${IFS}:=," read -r table_device _ table_start _ table_size _ _ _ table_name _; do
            if [ -z "${disk_start}" ] || [ -z "${table_start}" ] || \
               [ "${disk_start}" != "${table_start}" ]; then
                continue
            fi

            if [ ! -b "${disk_device}" ]; then
                echo "Error: '${disk_device}' is not a block device, cannot continue"
                exit 1
            fi

            if grep -q "${disk_device}" /proc/mounts; then
                umount "${disk_device}"
            fi

            # Get the partition number from the device. e.g. /dev/loop0p1 -> p1
            # by grouping p with 1 or more digits and only printing the match,
            # with | being used as the command separator.
            # and then format the partition. If the partition was already valid,
            # just resize the existing one. If fsck or resize fails, reformat.
            partition="$(echo "${disk_device}" | sed -rn 's|.*(p[[:digit:]]+$)|\1|p')"
            if fstype="$(blkid -o value -s TYPE "${TARGET_STORAGE_DEVICE}${partition}")"; then
                echo "Attempting to resize partition ${TARGET_STORAGE_DEVICE}${partition}"
                case "${fstype}" in
                ext4)
                    fsck_cmd="fsck.ext4 -f -y"
                    fsck_ret_ok="1"
                    mkfs_cmd="mkfs.ext4 -F -L ${table_name} -O ^extents,^64bit"
                    resize_cmd="resize2fs"
                    ;;
                f2fs)
                    fsck_cmd="fsck.f2fs -f -p -y"
                    fsck_ret_ok="0"
                    mkfs_cmd="mkfs.f2fs -f -l ${table_name}"
                    resize_cmd="resize.f2fs"
                    ;;
                esac

                # In some cases of fsck, other values then 0 are acceptable,
                # as such we need to capture the return value or else set -u
                # will trigger eval as a failure and abort the script.
                fsck_status="$(eval "${fsck_cmd}" "${TARGET_STORAGE_DEVICE}${partition}" 1> /dev/null; echo "${?}")"
                if [ "${fsck_ret_ok}" -ge "${fsck_status}" ] && \
                   ! eval "${resize_cmd}" "${TARGET_STORAGE_DEVICE}${partition}"; then
                        echo "Resize failed, formatting instead."
                        eval "${mkfs_cmd}" "${TARGET_STORAGE_DEVICE}${partition}"
                fi
            else
                echo "Formatting ${TARGET_STORAGE_DEVICE}${partition}"
                if [ "${disk_start}" -eq "${BOOT_PARTITION_START}" ]; then
                    mkfs_cmd="mkfs.ext4 -F -L ${table_name} -O ^extents,^64bit"
                else
                    mkfs_cmd="mkfs.f2fs -f -l ${table_name}"
                fi

                eval "${mkfs_cmd}" "${TARGET_STORAGE_DEVICE}${partition}"
            fi
        done < "${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}"
    done
}

partition_resize()
{
    if ! sha512sum -csw "${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}.sha512"; then
        echo "Error processing partition table: crc error."
        exit 1
    fi

    boot_partition_available=false

    # sfdisk returns size in blocks, * (1024 / 512) converts to sectors
    target_disk_end="$(($(sfdisk --quiet --show-size "${TARGET_STORAGE_DEVICE}" 2> /dev/null) * 2))"

    # Temporally expand the Input Field Separator with ':=,' and treat them
    # as whitespaces, in other words, ignore them.
    while IFS="${IFS}:=," read -r device _ start _ size _; do
        if [ -z "${device}" ] || is_comment "${device}" || \
           ! is_integer "${start}" || ! is_integer "${size}"; then
            continue
        fi

        if [ "${start}" -eq "${BOOT_PARTITION_START}" ]; then
            boot_partition_available=true
        fi

        partition_end="$((start + size))"
        if [ "${partition_end}" -gt "${target_disk_end}" ]; then
            echo "Partition '${device}' is beyond the size of the disk (${partition_end} > ${target_disk_end}), cannot continue."
            exit 1
        fi
    done < "${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}"

    if ! "${boot_partition_available}"; then
        echo "Error, no boot partition available, cannot continue."
        exit 1
    fi

    sfdisk --quiet "${TARGET_STORAGE_DEVICE}" < "${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}"
}

while getopts ":d:ht:" options; do
    case "${options}" in
    d)
        TARGET_STORAGE_DEVICE="${OPTARG}"
        ;;
    h)
        usage
        exit 0
        ;;
    t)
        PARTITION_TABLE_FILE="${OPTARG}"
        ;;
    :)
        echo "Option -${OPTARG} requires an argument."
        exit 1
        ;;
    ?)
        echo "Invalid option: -${OPTARG}"
        exit 1
        ;;
    esac
done
shift "$((OPTIND - 1))"

if [ -z "${PARTITION_TABLE_FILE}" ] || [ -z "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Missing arguments <PARTITION_TABLE_FILE> and/or <TARGET_STORAGE_DEVICE>."
    usage
    exit 1
fi

if [ ! -r "${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}" ]; then
    echo "Unable to read partition table file '${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}', cannot continue."
    exit 1
fi

if [ ! -b "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Error, block device '${TARGET_STORAGE_DEVICE}' does not exist."
    exit 1
fi

if ! is_resize_needed; then
    echo "Partition resize not required."
    exit 0
fi

partition_resize
partition_sync
partitions_format

exit 0
