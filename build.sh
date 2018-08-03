#!/bin/sh

set -eu

ARCH="${ARCH:-armhf}"
ARM_EMU_BIN="${ARM_EMU_BIN:-}"
CUR_DIR="$(pwd)"
BUILD_DIR="${CUR_DIR}/.build_${ARCH}"
ALPINE_VERSION="${ALPINE_VERSION:-latest-stable}"
ALPINE_REPO="${ALPINE_REPO:-http://dl-cdn.alpinelinux.org/alpine}"
TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-um-update_toolbox.xz.img}"
ROOTFS_DIR="${BUILD_DIR}/rootfs"

cleanup()
{
    mounts="$(grep "${ROOTFS_DIR}" /proc/mounts || true)"

    if [ ! -d "${BUILD_DIR}" ]; then
        return
    fi
    if [ -n "${mounts}" ]; then
        echo "Cannot delete '${BUILD_DIR}', unmount the following mount points first:"
        echo "${mounts}"
        exit 1
    fi

    rm -rf "${BUILD_DIR}"
}

bootstrap_prepare()
{
    if [ ! -x "${ARM_EMU_BIN}" ]; then
        echo "Invalid or missing ARMv7 interpreter. Please set ARM_EMU_BIN to a valid interpreter."
        echo "Run 'tests/buildenv.sh' to check emulation status."
        exit 1
    fi

    mkdir -p "${ROOTFS_DIR}/usr/bin"
    touch "${ROOTFS_DIR}/${ARM_EMU_BIN}"
    mount -o ro --bind "${ARM_EMU_BIN}" "${ROOTFS_DIR}/${ARM_EMU_BIN}"
}

bootstrap_unprepare()
{
    if [ ! -e "${ROOTFS_DIR}/${ARM_EMU_BIN}" ]; then
        return
    fi

    if grep -q "$(realpath "${ROOTFS_DIR}/${ARM_EMU_BIN}")" "/proc/mounts"; then
        umount "${ROOTFS_DIR}/${ARM_EMU_BIN}"
    fi
    if [ -f "${ROOTFS_DIR}/${ARM_EMU_BIN}" ]; then
        unlink "${ROOTFS_DIR}/${ARM_EMU_BIN}"
    fi
}

add_update_scripts()
{
    local_script_dir="${CUR_DIR}/scripts"
    target_script_dir="${ROOTFS_DIR}/sbin"
    entrypoint="startup.sh"

    if [ ! -f "${local_script_dir}/${entrypoint}" ]; then
        echo "Missing entrypoint script '${local_script_dir}/${entrypoint}'."
        exit 1
    fi

    for script in "${local_script_dir}"/*; do
        basename="${script##*/}"
        echo "Installing ${script} on '${target_script_dir}/${basename}'."
        cp "${script}" "${target_script_dir}/${basename}"
        chmod +x "${target_script_dir}/${basename}"
    done
}

bootstrap_rootfs()
{
    echo "Bootstrapping Alpine Linux rootfs in to '${ROOTFS_DIR}'."

    mkdir -p "${ROOTFS_DIR}/etc/apk"
    echo "${ALPINE_REPO}/${ALPINE_VERSION}/main" > "${ROOTFS_DIR}/etc/apk/repositories"
    # Install rootfs with base applications
    apk --root "${ROOTFS_DIR}" --update-cache \
       add --allow-untrusted --initdb --arch "${ARCH}" \
       busybox e2fsprogs-extra f2fs-tools rsync
    # Add baselayout etc files
    echo "Adding baselayout"
    apk --root "${ROOTFS_DIR}" \
       fetch --allow-untrusted --arch "${ARCH}" --stdout alpine-base | tar -xvz -C "${ROOTFS_DIR}" etc
    rm -f "${ROOTFS_DIR}/var/cache/apk"/*

    add_update_scripts
}

compress_rootfs()
{
    if [ -f "${BUILD_DIR}/${TOOLBOX_IMAGE}" ]; then
        rm -f "${BUILD_DIR}/${TOOLBOX_IMAGE}"
    fi

    echo "Compressing rootfs"
    mksquashfs "${ROOTFS_DIR}" "${BUILD_DIR}/${TOOLBOX_IMAGE}" -comp xz
    echo "Created ${BUILD_DIR}/${TOOLBOX_IMAGE}."
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

if [ "$(id -u)" -ne 0 ]; then
    echo "Warning: this script requires root permissions."
    echo "Run this script again with 'sudo ${0}'."
    echo "See ${0} -h for more info."
    exit 1
fi

trap bootstrap_unprepare EXIT

cleanup
bootstrap_prepare
bootstrap_rootfs
bootstrap_unprepare
compress_rootfs

exit 0
