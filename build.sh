#!/bin/sh

set -eu

ARCH="${ARCH:-armhf}"
CUR_DIR="$(pwd)"
BUILD_DIR="${CUR_DIR}/.build_${ARCH}"
ALPINE_VERSION="${ALPINE_VERSION:-latest-stable}"
ALPINE_REPO="${ALPINE_REPO:-http://dl-cdn.alpinelinux.org/alpine}"
ROOTFS_ARCHIVE="rootfs.xz.img"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
RUN_SUDO=""


cleanup()
{
    mount_points="$(grep "${ROOTFS_DIR}" /proc/mounts || true)"

    if [ ! -d "${BUILD_DIR}" ]; then
        return
    fi
    if [ -n "${mount_points}" ]; then
        echo "Cannot delete '${BUILD_DIR}', unmount the following mount points first:"
        echo "${mount_points}"
        exit 1
    fi

    "${RUN_SUDO}"rm -rf "${BUILD_DIR}"
}

bootstrap_rootfs()
{
    echo "Bootstrapping Alpine Linux rootfs in to ${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}/etc/apk"
    echo "${ALPINE_REPO}/${ALPINE_VERSION}/main" > "${ROOTFS_DIR}/etc/apk/repositories"
    # Install rootfs with base applications
    "${RUN_SUDO}"apk --root "${ROOTFS_DIR}" --update-cache \
       add --allow-untrusted --initdb --arch "${ARCH}" \
       busybox e2fsprogs-extra f2fs-tools rsync
    # Add baselayout etc files
    echo "Adding baselayout"
    "${RUN_SUDO}"apk --root "${ROOTFS_DIR}" \
       fetch --allow-untrusted --arch "${ARCH}" --stdout alpine-base | tar -xvz -C "${ROOTFS_DIR}" etc
    "${RUN_SUDO}"rm -f "${ROOTFS_DIR}/var/cache/apk"/*
}

compress_rootfs()
{
    if [ -f "${ROOTFS_ARCHIVE}" ]; then
        "${RUN_SUDO}"rm -f "${ROOTFS_ARCHIVE}"
    fi

    echo "Compressing rootfs"
    "${RUN_SUDO}"mksquashfs "${ROOTFS_DIR}" "${ROOTFS_ARCHIVE}" -comp xz
    echo "Created ${ROOTFS_ARCHIVE}."
}

usage()
{
cat <<-EOT
    Usage: ${0} [OPTIONS]
        -c   Explicitly cleanup the build directory
        -h   Print this usage
    NOTE: This script requires root permissions to run.
EOT
}

while getopts ":hc" options; do
    case "${options}" in
    c)
        cleanup
        exit 0
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

if [ "$(id -u)" != "0" ]; then
    RUN_SUDO="sudo"
fi


cleanup
bootstrap_rootfs
compress_rootfs

exit 0
