#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

# Script mandatory arguments
# The mount point of the update toolbox, used as chroot root.
TOOLBOX_MOUNT=""
# The mount point where the update archive and this toolbox where found
UPDATE_MOUNT=""
# The target update storage device
TARGET_STORAGE_DEVICE=""


usage()
{
    echo "Usage: ${0} [OPTIONS] <TOOLBOX_MOUNT> <UPDATE_MOUNT> <TARGET_STORAGE_DEVICE>"
    echo "This is the update entry point script, it is responsible for setting up the"
    echo "environment in which the update toolbox can be used to configure and update"
    echo "the firmware."
    echo "  -h Print this help text and exit"
}

while getopts ":h" options; do
    case "${options}" in
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

if [ "${#}" -lt 3 ]; then
    echo "Missing arguments."
    usage
    exit 1
fi

if [ "${#}" -gt 3 ]; then
    echo "Too many arguments."
    usage
    exit 1
fi

TOOLBOX_MOUNT="${1}"
UPDATE_MOUNT="${2}"
TARGET_STORAGE_DEVICE="${3}"

if [ -z "${TOOLBOX_MOUNT}" ]; then
    echo "Error, update failed: Missing arguments <TOOLBOX_MOUNT>."
    exit 1
fi

if [ ! -d "${TOOLBOX_MOUNT}" ]; then
    echo "Error, update failed: ${TOOLBOX_MOUNT} is not a directory."
    exit 1
fi

if [ -z "${UPDATE_MOUNT}" ]; then
    echo "Error, update failed: update mount dir is not provided."
    exit 1
fi

if [ ! -d "${UPDATE_MOUNT}" ]; then
    echo "Error, update failed: ${UPDATE_MOUNT} is not a directory."
    exit 1
fi

if [ -z "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Error, update failed: target storage device not provided."
    exit 1
fi

if [ ! -b "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Error, update failed: '${TARGET_STORAGE_DEVICE}' is not a block device."
    exit 1
fi

if [ -z "${SYSTEM_UPDATE_DIR}" ]; then
    echo "Error, update failed: system update dir is not provided."
    exit 1
fi

if [ ! -d "${TOOLBOX_MOUNT}${SYSTEM_UPDATE_DIR}" ]; then
    echo "Error, update failed: ${TOOLBOX_MOUNT}${SYSTEM_UPDATE_DIR} is not a directory."
    exit 1
fi

if [ ! -r "${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}" ]; then
    echo "Error, update failed: '${TOOLBOX_MOUNT}/${TOOLBOX_MOUNT}${SYSTEM_UPDATE_DIR}/${PARTITION_TABLE_FILE}' is not readable."
    exit 1
fi

if [ ! -r "${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_DIR}/${UPDATE_EXCLUDE_LIST_FILE}" ]; then
    echo "Error, update failed: '${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_DIR}/${UPDATE_EXCLUDE_LIST_FILE}' is not readable."
    exit 1
fi


if ! extract_update_rootfs; then
   echo "Update failed: unable to prepare update files."
   exit 1
fi

# sort scripts with globbing
# execute all scripts in chroot
cleanup

echo "Ok, update success."

exit 0
