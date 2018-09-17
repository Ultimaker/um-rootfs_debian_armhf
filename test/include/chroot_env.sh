#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
#
# SPDX-License-Identifier: AGPL-3.0+

ARM_EMU_BIN="${ARM_EMU_BIN:-}"

overlayfs_dir=""
is_dev_setup_mounted=false

setup_chroot_env()
{
    image_file="${1}"
    target_root_dir="${2}"

    echo "Setup chroot env."

    # devtmps needs to be re-mounted when running in docker
    if ! grep -qE "/dev.*devtmpfs" "/proc/mounts"; then
        mount -t "devtmpfs" "none" "/dev"
        is_dev_setup_mounted=true
    fi

    # overlayfs is required because we need to write data
    # in the ro squashfs for testing purposes,
    # e.g. ARM_EMU_BIN mount point and temporary test files.
    overlayfs_dir="$(mktemp -d -t "overlayfs.XXXXXXXXXX")"

    mount -t "tmpfs" "none" "${overlayfs_dir}"
    mkdir "${overlayfs_dir}/rom"
    mkdir "${overlayfs_dir}/up"
    mkdir "${overlayfs_dir}/work"

    mount "${image_file}" "${overlayfs_dir}/rom"
    mount -t overlay overlay \
          -o "lowerdir=${overlayfs_dir}/rom,upperdir=${overlayfs_dir}/up,workdir=${overlayfs_dir}/work" \
          "${target_root_dir}"

    mount --bind "/proc" "${target_root_dir}/proc"
    ln -s ../proc/self/mounts "${target_root_dir}/etc/mtab"
    mount -t "devtmpfs" "none" "${target_root_dir}/dev"

    if [ ! -x "${ARM_EMU_BIN}" ]; then
        echo "Invalid or missing ARMv7 interpreter. Please set ARM_EMU_BIN to a valid interpreter."
        echo "Run 'tests/buildenv.sh' to check emulation status."
        exit 1
    fi

    touch "${target_root_dir}${ARM_EMU_BIN}"
    mount --bind -o "ro" "${ARM_EMU_BIN}" "${target_root_dir}${ARM_EMU_BIN}"
}

teardown_chroot_env()
{
    target_root_dir="${1}"

    echo "Teardown chroot env."

    if [ -f "${target_root_dir}${ARM_EMU_BIN}" ]; then
        if grep -q "$(realpath "${target_root_dir}${ARM_EMU_BIN}")" "/proc/mounts"; then
            umount "${target_root_dir}${ARM_EMU_BIN}"
        fi
        if [ -f "${target_root_dir}${ARM_EMU_BIN}" ]; then
            unlink "${target_root_dir}${ARM_EMU_BIN}"
        fi
    fi

    if grep -q "${target_root_dir}/dev" "/proc/mounts"; then
        umount "${target_root_dir}/dev"
    fi

    if grep -q "${target_root_dir}/proc" "/proc/mounts"; then
        umount "${target_root_dir}/proc"
    fi

    mounts="${overlayfs_dir}/rom ${overlayfs_dir}"
    for mount in ${mounts}; do
        if grep -q "${mount}" "/proc/mounts"; then
            umount "${mount}"
        fi
        if [ -d "${mount}" ] && [ -z "${mount##*overlayfs_*}" ]; then
            rm -r "${mount:?}"
        fi
    done

    if "${is_dev_setup_mounted}"; then
        umount "/dev"
        is_dev_setup_mounted=false
    fi
}

failure_exit_chroot_env()
{
    echo "    umount '${target_root_dir}/${ARM_EMU_BIN}' && \\"
    echo "    unlink '${target_root_dir}/${ARM_EMU_BIN}' && \\"
    echo "    umount '${target_root_dir}/dev' && \\"
    echo "    if '${is_dev_setup_mounted}'; then \\"
    echo "      umount '/dev' \\"
    echo "    fi && \\"
    echo "    umount '${target_root_dir}/proc' && \\"
    echo "    umount '${target_root_dir}' && \\"
    echo "    rmdir '${target_root_dir}' && \\"
    echo "    umount '${overlayfs_dir}/rom' && \\"
    echo "    rmdir '${overlayfs_dir}/rom' && \\"
    echo "    umount '${overlayfs_dir}/' && \\"
    echo "    rmdir '${overlayfs_dir}/'"
}
