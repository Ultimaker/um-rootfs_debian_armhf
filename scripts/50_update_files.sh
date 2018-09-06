#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

# system_update wide configuration settings with default values
SYSTEM_UPDATE_DIR="${SYSTEM_UPDATE_DIR:-/etc/system_update}"
UPDATE_EXCLUDE_LIST_FILE="${UPDATE_EXCLUDE_LIST_FILE:-jedi_update_exclude_list.txt}"
TARGET_STORAGE_DEVICE="${TARGET_STORAGE_DEVICE:-}"
UPDATE_ROOTFS_SOURCE="${UPDATE_ROOTFS_SOURCE:-}"
# end system_update wide configuration settings

UPDATE_TARGET="/tmp/target_root"

usage()
{
    echo "Usage: ${0} [OPTIONS]"
    echo "Synchronize the files from 'UPDATE_SOURCE' to 'TARGET_STORAGE_DEVICE'"
    echo "second partition, while taking into account a set of exclude files"
    echo "and directories from the 'exclude list file'."
    echo "  -d <TARGET_STORAGE_DEVICE>, the target storage device for the update"
    echo "  -h Print this help text and exit"
    echo "  -s <UPDATE_SOURCE>, the source directory where to find the update files"
    echo "Note: the UPDATE_SOURCE and TARGET_STORAGE_DEVICE arguments can also be passed by"
    echo "adding them to the scripts runtime environment."
}

perform_update()
{
    if [ ! -d "${UPDATE_TARGET}" ]; then
        mkdir -p "${UPDATE_TARGET}"
    fi

    if ! mount -t auto -v "${TARGET_STORAGE_DEVICE}p2" "${UPDATE_TARGET}"; then
        echo "Error: unable to mount '${TARGET_STORAGE_DEVICE}p2'."
        exit 1
    fi

    if ! rsync --exclude-from "${SYSTEM_UPDATE_DIR}/${UPDATE_EXCLUDE_LIST_FILE}" -c -a --delete -x \
        "${UPDATE_ROOTFS_SOURCE}/" "${UPDATE_TARGET}/"; then
        echo "Error: unable to sync files from ${UPDATE_ROOTFS_SOURCE}/ to ${UPDATE_TARGET}/."
        exit 1
    fi

    if grep -qE "${UPDATE_TARGET}" "/proc/mounts"; then
        umount "${UPDATE_TARGET}"
    fi
}

while getopts ":d:hs:" options; do
    case "${options}" in
    d)
        TARGET_STORAGE_DEVICE="${OPTARG}"
        ;;
    h)
        usage
        exit 0
        ;;
    s)
        UPDATE_ROOTFS_SOURCE="${OPTARG}"
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

if [ -z "${UPDATE_ROOTFS_SOURCE}" ] || [ -z "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Missing arguments <UPDATE_ROOTFS_SOURCE> and/or <TARGET_STORAGE_DEVICE>."
    usage
    exit 1
fi

if [ ! -d "${UPDATE_ROOTFS_SOURCE}" ]; then
    echo "Update failed: ${UPDATE_ROOTFS_SOURCE} does not exist."
    exit 1
fi

if [ ! -b "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Update failed: ${TARGET_STORAGE_DEVICE} is not a valid block device."
    exit 1
fi

perform_update

exit 0
