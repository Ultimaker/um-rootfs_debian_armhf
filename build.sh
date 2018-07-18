#!/bin/sh

set -eu

ARCH="${ARCH:-armhf}"
CUR_DIR="$(pwd)"
BUILD_DIR="${CUR_DIR}/.build_${ARCH}"
DEBIAN_VERSION="${DEBIAN_VERSION:-jessie}"
ROOTFS_ARCHIVE="rootfs.tar.xz"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
QEMU_STATIC_BIN="$(command -v qemu-arm-static)"


cleanup()
{
    local mount_points
    mount_points="$(mount | grep "${ROOTFS_DIR}")"

    if [ "${mount_points}" = "" ]; then
        if [ -d "${BUILD_DIR}" ]; then
            rm -rf "${BUILD_DIR}"
        fi
    else
        echo "Cannot delete ${ROOTFS_DIR}, unmount the following mount points first:"
        echo "${mount_points}"
    fi
}

prepare_bootstrap()
{
    if [ ! -d "${ROOTFS_DIR}/usr/bin" ]; then
        mkdir -p "${ROOTFS_DIR}/usr/bin"
    fi

    if [ ! -x "${ROOTFS_DIR}${QEMU_STATIC_BIN}" ]; then
        cp "${QEMU_STATIC_BIN}" "${ROOTFS_DIR}/usr/bin/"
    fi
}

un_prepare_bootstrap()
{
    if [ -f "${ROOTFS_DIR}${QEMU_STATIC_BIN}" ]; then
        rm  -f "${ROOTFS_DIR}${QEMU_STATIC_BIN}"
    fi
}

bootstrap_rootfs()
{

    printf "Bootstrapping rootfs to %s\\n" "${ROOTFS_DIR}"
    debootstrap \
        --arch=armhf \
        --variant=minbase \
        --include=f2fs-tools,mtd-utils,busybox,udisks2,rsync \
        "${DEBIAN_VERSION}" "${ROOTFS_DIR}" http://ftp.debian.com/debian
}

#strip_rootfs()
#{
#   TODO: Strip even more see issue EMP-324 Reduce rootfs size
#}

compress_rootfs()
{
    if [ -f "${BUILD_DIR}/${ROOTFS_ARCHIVE}" ]; then
        rm -f "${BUILD_DIR}/${ROOTFS_ARCHIVE}"
    fi

    printf "Compressing rootfs\\n"
    tar -cJf "${BUILD_DIR}/${ROOTFS_ARCHIVE}" -C "${ROOTFS_DIR}" .
    printf "Created %s\\n" "${ROOTFS_ARCHIVE}"
}

usage()
{
cat <<-EOT
    Usage: ${0} [OPTIONS]
        -c   Cleanup, after a run you have the possibility to get the artifact and then cleanup
        -h   Print usage
    NOTE: This script requires root permissions to run.
EOT
}

if [ "$(id -u)" != "0" ]; then
    printf "Make sure this script is run with root permissions\\n"
    usage
    exit 1
fi

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
            printf "Option -%s requires an argument.\\n" "${OPTARG}"
            ;;
        ?)
            printf "Invalid option: -%s\\n" "${OPTARG}"
            ;;
    esac
done
shift "$((OPTIND - 1))"


cleanup
prepare_bootstrap
bootstrap_rootfs
un_prepare_bootstrap
#strip_rootfs
compress_rootfs

exit 0