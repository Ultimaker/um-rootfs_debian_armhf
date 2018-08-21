#!/bin/sh
#
# SPDX-License-Identifier: AGPL-3.0+
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
#

set -eu

PARTITION_TABLE_FILE="${PARTITION_TABLE_FILE:-}"
TARGET_DISK="${TARGET_DISK:-}"

BOOT_PARTITION_START="2048"

usage()
{
    echo "Usage: ${0} [OPTIONS] <DISK>"
    echo "Prepare the target DISK to a predefined disk layout."
    echo "  -t Partition table file (mandatory)."
    echo "  -h Print this help text and exit"
    echo "NOTE: This script is destructive and will destroy your data."
}

partition_resize()
{
    if ! sha512sum -csw "${PARTITION_TABLE_FILE}.sha512"; then
        echo "Error processing partition table: crc error."
        exit 1
    fi

    boot_partition_available=false

    # Temporally expand the Input Field Separator with ':=,' and treat them
    # as whitespaces, in other words, ignore them.
    while IFS="${IFS}:=," read -r label _ start _ size _ _ _; do
        # Invalidate lines that are: empty, start with #, start and size that
        # are not integers by using an inverse integer comparison test.
        if [ -z "${label}" ] || \
           [ -z "${label%%#*}" ] || \
           ! [ "${start}" -eq "${start}" ] 2> /dev/null || \
           ! [ "${size}" -eq "${size}" ] 2> /dev/null; then
            continue
        fi

        if [ "${start}" -eq "${BOOT_PARTITION_START}" ]; then
            boot_partition_available=true
        fi

        partition_end="$((start + size))"
        # sfdisk returns size in blocks, * (1024 / 512) converts to sectors
        target_disk_end="$(($(sfdisk -s "${TARGET_DISK}" 2> /dev/null) * 2))"
        if [ "${partition_end}" -gt "${target_disk_end}" ]; then
            echo "Partition '${label}' is beyond the size of the disk (${partition_end} > ${target_disk_end}), cannot continue."
            exit 1
        fi
    done < "${PARTITION_TABLE_FILE}"

    if ! "${boot_partition_available}"; then
        echo "Error, no boot partition available, cannot continue."
        exit 1
    fi

    sfdisk "${TARGET_DISK}" < "${PARTITION_TABLE_FILE}"
    partprobe "${TARGET_DISK}"
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

partition_resize

exit 0
