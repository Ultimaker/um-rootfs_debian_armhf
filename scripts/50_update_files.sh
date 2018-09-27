#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

trap cleanup EXIT

# common directory variables
SYSCONFDIR="${SYSCONFDIR:-/etc}"

# system_update wide configuration settings with default values
SYSTEM_UPDATE_CONF_DIR="${SYSTEM_UPDATE_CONF_DIR:-${SYSCONFDIR}/jedi_system_update}"
TARGET_STORAGE_DEVICE="${TARGET_STORAGE_DEVICE:-}"
UPDATE_ROOTFS_SOURCE="${UPDATE_ROOTFS_SOURCE:-}"
# end system_update wide configuration settings

NAME_TEMPLATE_UPDATE_TARGET="um-target_root"
UPDATE_TARGET="$(mktemp -d -t "${NAME_TEMPLATE_UPDATE_TARGET}.XXXXXX")"

usage()
{
    echo "Usage: ${0} [OPTIONS]"
    echo "Synchronize the files from 'UPDATE_ROOTFS_SOURCE' to 'TARGET_STORAGE_DEVICE'"
    echo "second partition, while taking into account a set of exclude files"
    echo "and directories from the 'exclude list file'."
    echo "  -d <TARGET_STORAGE_DEVICE>, the target storage device for the update"
    echo "  -h Print this help text and exit"
    echo "  -s <UPDATE_SOURCE>, the source directory where to find the update files"
    echo "Note: the UPDATE_SOURCE and TARGET_STORAGE_DEVICE arguments can also be passed by"
    echo "adding them to the scripts runtime environment."
}

cleanup()
{
    # On slow media, umount and/or rmdir can fail with 'resource busy' errors.
    # To do our best with cleanup, attempt this a few times before giving up.
    failed=0
    while test -d "${UPDATE_TARGET}"; do
        if grep -q "${UPDATE_TARGET}" "/proc/mounts"; then
            if ! umount "${UPDATE_TARGET}"; then
                failed="$((failed + 1))"
            fi
        fi

        if [ -d "${UPDATE_TARGET}" ] && \
           [ -z "${UPDATE_TARGET##*${NAME_TEMPLATE_UPDATE_TARGET}*}" ]; then
            if ! rmdir "${UPDATE_TARGET}"; then
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

perform_update()
{
    if [ ! -d "${UPDATE_TARGET}" ]; then
        echo "Unable to perform update, missing update target directory."
        exit 1
    fi

    if ! mount -t auto -v "${TARGET_STORAGE_DEVICE}p2" "${UPDATE_TARGET}"; then
        echo "Error: unable to mount '${TARGET_STORAGE_DEVICE}p2'."
        exit 1
    fi

    # Note that with rsync --delete, we want to ensure both the '.keep' as
    # well as the '.discard' file are ignored.
    for exclude in "${SYSTEM_UPDATE_CONF_DIR}/"*".keep" \
                   "${SYSTEM_UPDATE_CONF_DIR}/"*".discard" \
                   "${UPDATE_ROOTFS_SOURCE}/${SYSTEM_UPDATE_CONF_DIR}"*".keep" \
                   "${UPDATE_ROOTFS_SOURCE}/${SYSTEM_UPDATE_CONF_DIR}"*".discard"; do
        exclude_list="${exclude_list:-} --exclude-from ${exclude}"
    done

    if ! eval rsync -a -c -x --delete \
        "${UPDATE_ROOTFS_SOURCE}/" "${UPDATE_TARGET}/" "${exclude_list}"; then
        echo "Error: unable to sync files from ${UPDATE_ROOTFS_SOURCE}/ to ${UPDATE_TARGET}/."
        exit 1
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

if [ -z "${UPDATE_ROOTFS_SOURCE}" ]; then
    echo "Missing arguments <UPDATE_ROOTFS_SOURCE>."
    usage
    exit 1
fi

if [ -z "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Missing arguments <TARGET_STORAGE_DEVICE>."
    usage
    exit 1
fi

if [ ! -d "${UPDATE_ROOTFS_SOURCE}" ]; then
    echo "Update failed: '${UPDATE_ROOTFS_SOURCE}' does not exist."
    usage
    exit 1
fi

if ! cat "${UPDATE_ROOTFS_SOURCE}/etc/debian_version" 2> /dev/null; then
    echo "Update failed: no Debian distribution found."
    usage
    exit 1
fi

if ! cat "${UPDATE_ROOTFS_SOURCE}/etc/ultimaker_version" 2> /dev/null; then
    echo "Update failed: no Ultimaker software found."
    usage
    exit 1
fi

if [ ! -b "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Update failed: '${TARGET_STORAGE_DEVICE}' is not a valid block device."
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

echo "Updating to Ultimaker version: $(cat "${UPDATE_ROOTFS_SOURCE}/etc/ultimaker_version")"

perform_update
cleanup

exit 0
