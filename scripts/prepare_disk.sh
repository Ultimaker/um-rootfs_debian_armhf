#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

PARTITION_TABLE_FILE="${PARTITION_TABLE_FILE:-}"
TARGET_DISK="${TARGET_DISK:-}"

BOOT_PARTITION_START="2048"

usage()
{
    echo "Usage: ${0} [OPTIONS] <DISK>"
    echo "Prepare the target DISK to a predefined disk layout."
    echo "  -t Partition table file (mandatory)"
    echo "  -h Print this help text and exit"
    echo "NOTE: This script is destructive and will destroy your data."
}

partition_sync()
{
    i=10
    while [ "${i}" -gt 0 ]; do
        if partprobe "${TARGET_DISK}"; then
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
    sfdisk --quiet -d "${TARGET_DISK}" | \
    while IFS="${IFS}:=," read -r disk_label _ disk_start _ disk_size _; do
        while IFS="${IFS}:=," read -r table_label _ table_start _ table_size _; do
            if [ -z "${disk_start}" ] || [ -z "${table_start}" ] || \
               [ "${disk_start}" != "${table_start}" ]; then
                continue
            fi

            if grep -q "${disk_label}" /proc/mounts; then
                umount "${disk_label}"
            fi

            # Get the partition number from the label. e.g. /dev/loop0p1 -> p1
            # by grouping p with 1 or more digits and only printing the match,
            # with | being used as the command separator.
            # and then format the partition. If the partition was already valid,
            # just resize the existing one. If fsck or resize fails, reformat.
            partition="$(echo "${disk_label}" | sed -rn 's|.*(p[[:digit:]]+$)|\1|p')"
            if fstype="$(blkid -o value -s TYPE "${TARGET_DISK}${partition}")"; then
                echo "Attempting to resize partition ${TARGET_DISK}${partition}"
                case "${fstype}" in
                ext4)
                    fsck_cmd="fsck.ext4 -f -y"
                    fsck_ret_ok="1"
                    mkfs_cmd="mkfs.ext4 -F -L ${table_label}"
                    resize_cmd="resize2fs"
                    ;;
                f2fs)
                    fsck_cmd="fsck.f2fs -f -p -y"
                    fsck_ret_ok="0"
                    mkfs_cmd="mkfs.f2fs -f -l ${table_label}"
                    resize_cmd="resize.f2fs"
                    ;;
                esac

                # In some cases of fsck, other values then 0 are acceptable,
                # as such we need to capture the return value or else set -u
                # will trigger eval as a failure and abort the script.
                fsck_status="$(eval "${fsck_cmd}" "${TARGET_DISK}${partition}" 1> /dev/null; echo "${?}")"
                if [ "${fsck_ret_ok}" -ge "${fsck_status}" ] && \
                   ! eval "${resize_cmd}" "${TARGET_DISK}${partition}"; then
                        echo "Resize failed, formatting instead."
                        eval "${mkfs_cmd}" "${TARGET_DISK}${partition}"
                fi
            else
                echo "Formatting ${TARGET_DISK}${partition}"
                if [ "${disk_start}" -eq "${BOOT_PARTITION_START}" ]; then
                    mkfs_cmd="mkfs.ext4 -L ${table_label}"
                else
                    mkfs_cmd="mkfs.f2fs -l ${table_label}"
                fi

                eval "${mkfs_cmd}" "${TARGET_DISK}${partition}"
            fi
        done < "${PARTITION_TABLE_FILE}"
    done
}

partition_resize()
{
    is_integer()
    {
        test "${1}" -eq "${1}" 2> /dev/null
    }

    is_comment()
    {
        test -z "${1%%#*}"
    }

    if ! sha512sum -csw "${PARTITION_TABLE_FILE}.sha512"; then
        echo "Error processing partition table: crc error."
        exit 1
    fi

    boot_partition_available=false

    # Temporally expand the Input Field Separator with ':=,' and treat them
    # as whitespaces, in other words, ignore them.
    while IFS="${IFS}:=," read -r label _ start _ size _; do
        if [ -z "${label}" ] || is_comment "${label}" || \
           ! is_integer "${start}" || ! is_integer "${size}"; then
            continue
        fi

        if [ "${start}" -eq "${BOOT_PARTITION_START}" ]; then
            boot_partition_available=true
        fi

        partition_end="$((start + size))"
        # sfdisk returns size in blocks, * (1024 / 512) converts to sectors
        target_disk_end="$(($(sfdisk --quiet --show-size "${TARGET_DISK}" 2> /dev/null) * 2))"
        if [ "${partition_end}" -gt "${target_disk_end}" ]; then
            echo "Partition '${label}' is beyond the size of the disk (${partition_end} > ${target_disk_end}), cannot continue."
            exit 1
        fi
    done < "${PARTITION_TABLE_FILE}"

    if ! "${boot_partition_available}"; then
        echo "Error, no boot partition available, cannot continue."
        exit 1
    fi

    sfdisk --quiet "${TARGET_DISK}" < "${PARTITION_TABLE_FILE}"
}

while getopts ":t:h" options; do
    case "${options}" in
    t)
        PARTITION_TABLE_FILE="${OPTARG}"
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
        echo "Invalid option: -${OPTARG}"
        exit 1
        ;;
    esac
done
shift "$((OPTIND - 1))"

if [ "${#}" -lt 1 ]; then
    echo "Missing argument <disk>."
    usage
    exit 1
fi

if [ "${#}" -gt 1 ]; then
    echo "Too many arguments."
    usage
    exit 1
fi

TARGET_DISK="${*}"

if [ ! -r "${PARTITION_TABLE_FILE}" ]; then
    echo "Unable to read partition table file '${PARTITION_TABLE_FILE}', cannot continue."
    exit 1
fi

echo "Availabe loop device partitions"

ls -la "${TARGET_DISK}"*

partition_resize
partition_sync
partitions_format

exit 0
