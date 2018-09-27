#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

trap cleanup EXIT

# system_update wide configuration settings
SYSTEM_UPDATE_CONF_DIR="${SYSTEM_UPDATE_CONF_DIR:-}"
TARGET_STORAGE_DEVICE="${TARGET_STORAGE_DEVICE:-}"
UPDATE_ROOTFS_SOURCE="${UPDATE_ROOTFS_SOURCE:-}"
UPDATE_SAVE_DIR="${UPDATE_SAVE_DIR:-}"
# end system_update wide configuration settings

KEEP_LIST="$(mktemp)"

NAME_TEMPLATE_TARGET_MOUNT="um-save_mount"
TARGET_MOUNT="$(mktemp -d -t "${NAME_TEMPLATE_TARGET_MOUNT}.XXXXXX")"

usage()
{
    echo "Usage: ${0} [OPTIONS]"
    echo "Save the data files from the TARGET_STORAGE_DEVICE."
    echo "  -d <TARGET_STORAGE_DEVICE>, the target storage device"
    echo "  -h Print this help text and exit"
    echo "  -k <SYSTEM_UPDATE_CONF_DIR>, directory that contains files ending with .keep extension containing files and directories to be saved up"
    echo "  -s <UPDATE_SAVE_DIR>, location that will hold the created archives"
    echo "Note: that all arguments can also be passed by adding them to the environment."
}

cleanup()
{
    if [ -f "${KEEP_LIST}" ]; then
        unlink "${KEEP_LIST}"
    fi

    # On slow media, umount and/or rmdir can fail with 'resource busy' errors.
    # To do our best with cleanup, attempt this a few times before giving up.
    failed=0
    while test -d "${TARGET_MOUNT}"; do
        if grep -q "${TARGET_MOUNT}" "/proc/mounts"; then
            if ! umount "${TARGET_MOUNT}"; then
                failed="$((failed + 1))"
            fi
        fi

        if [ -d "${TARGET_MOUNT}" ] && \
           [ -z "${TARGET_MOUNT##*${NAME_TEMPLATE_TARGET_MOUNT}*}" ]; then
            if ! rmdir "${TARGET_MOUNT}"; then
                failed="$((failed + 1))"
            fi
        fi

        if [ "${failed}" -ge 300 ]; then
            echo "Failed to properly cleanup."
            exit 1
        fi

        sleep 1
    done
}

save_data()
{
    echo "Saving data ..."

    for keep in "${SYSTEM_UPDATE_CONF_DIR}/"*".keep" \
                "${UPDATE_ROOTFS_SOURCE}/${SYSTEM_UPDATE_CONF_DIR}/"*".keep"; do
        if [ ! -r "${keep}" ]; then
            continue
        fi

        # Tar likes its exclude list to be relative, so replace the initial
        # '/' on a line with './'.
        sed s,^/,./, "${keep}" >> "${KEEP_LIST}"
    done

    for partition in "${TARGET_STORAGE_DEVICE}"*; do
        if [ ! -b "${partition}" ] || \
           ! mount -t auto "${partition}" "${TARGET_MOUNT}" 2> /dev/null; then
            continue
        fi

        update_target="${TARGET_MOUNT}"

        # When using overlay's, the actual data is stored in the 'upper'
        # sub-directory, as such, we use that as our 'root' directory.
        if [ -d "${TARGET_MOUNT}/upper" ]; then
            update_target="${TARGET_MOUNT}/upper"
        fi

        update_archive="${UPDATE_SAVE_DIR}/$(basename "${partition}").tar.xz"
        tar --ignore-failed-read -cJf "${update_archive}" -C "${update_target}" --files-from "${KEEP_LIST}" 2> /dev/null
        tar -tJf "${update_archive} 1> /dev/null"
        echo "Successfully saved data in '${update_archive}'."
    done

    echo "Done saving data."
}

while getopts ":d:hk:s:" options; do
    case "${options}" in
    d)
        TARGET_STORAGE_DEVICE="${OPTARG}"
        ;;
    h)
        usage
        exit 0
        ;;
    k)
        SYSTEM_UPDATE_CONF_DIR="${OPTARG}"
        ;;
    s)
        UPDATE_SAVE_DIR="${OPTARG}"
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

if [ ! -b "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Missing or invalid <TARGET_STORAGE_DEVICE>."
    usage
    exit 1
fi

if [ ! -d "${SYSTEM_UPDATE_CONF_DIR}" ]; then
    echo "Missing toolbox directory containing filter files, cannot continue."
    usage
    exit 1
fi

if [ ! -d "${UPDATE_ROOTFS_SOURCE}/${SYSTEM_UPDATE_CONF_DIR}" ]; then
    echo "Missing rootfs directory containing filter files, cannot continue."
    usage
    exit 1
fi

if [ ! -d "${UPDATE_SAVE_DIR}" ]; then
    echo "Missing directory to save files to, cannot continue."
    usage
    exit 1
fi

if [ ! -f "${KEEP_LIST}" ]; then
    echo "Nothing to save according to '${SYSTEM_UPDATE_CONF_DIR}'."
    exit 0
fi

save_data
cleanup

exit 0
