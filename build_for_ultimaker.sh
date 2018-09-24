#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

CI_REGISTRY_IMAGE="${CI_REGISTRY_IMAGE:-registry.gitlab.com/ultimaker/embedded/platform/um-update_toolbox_armhf}"
CI_REGISTRY_IMAGE_TAG="${CI_REGISTRY_IMAGE_TAG:-latest}"

ARCH="${ARCH:-armhf}"
ARM_EMU_BIN=
NAME_TEMPLATE_BUILD_DIR=".build_${ARCH}"
BUILD_DIR="${NAME_TEMPLATE_BUILD_DIR}"
PREFIX="${PREFIX:-/usr}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
TOOLBOX_IMAGE="um-update_toolbox.xz.img"

DOCKER_WORK_DIR="${DOCKER_WORK_DIR:-/build}"

ARMv7_MAGIC="7f454c4601010100000000000000000002002800"

run_env_check="yes"
run_tests="yes"


cleanup()
{
    unset ARM_EMU_BIN
}

update_docker_image()
{
    if ! docker pull "${CI_REGISTRY_IMAGE}:${CI_REGISTRY_IMAGE_TAG}" 2> /dev/null; then
        echo "Unable to update docker image '${CI_REGISTRY_IMAGE}:${CI_REGISTRY_IMAGE_TAG}', building locally instead."
        docker build . -t "${CI_REGISTRY_IMAGE}:${CI_REGISTRY_IMAGE_TAG}"
    fi
}

setup_emulation_support()
{
    for emu in /proc/sys/fs/binfmt_misc/*; do
        if [ ! -r "${emu}" ]; then
            continue
        fi

        if grep -q "${ARMv7_MAGIC}" "${emu}"; then
            ARM_EMU_BIN="$(sed 's/interpreter //;t;d' "${emu}")"
            break
        fi
    done

    if [ ! -x "${ARM_EMU_BIN}" ]; then
        echo "Unusable ARMv7 interpreter '${ARM_EMU_BIN}'."
        echo "Install an arm-emulator, such as qemu-arm-static for example."
        exit 1
    fi

    export ARM_EMU_BIN
}

run_in_docker()
{
    docker run \
        --privileged \
        --rm \
        -e "ARCH=${ARCH}" \
        -e "ARM_EMU_BIN=${ARM_EMU_BIN}" \
        -e "PREFIX=${PREFIX}" \
        -e "RELEASE_VERSION=${RELEASE_VERSION}" \
        -v "$(pwd):${DOCKER_WORK_DIR}" \
        -v "${ARM_EMU_BIN}:${ARM_EMU_BIN}:ro" \
        -w "${DOCKER_WORK_DIR}" \
        "${CI_REGISTRY_IMAGE}:${CI_REGISTRY_IMAGE_TAG}" \
        "${@}"
}

run_in_shell()
{
    ARCH="${ARCH}" \
    PREFIX="${PREFIX}" \
    RELEASE_VERSION="${RELEASE_VERSION}" \
    eval "${@}"
}

run_script()
{
    if ! command -V docker; then
        echo "Docker not found, attempting native build."

        run_in_shell "${@}"
    else
        run_in_docker "${@}"
    fi
}

env_check()
{
    run_script "./test/buildenv.sh"
}

run_build()
{
    run_script "./build.sh"
}

deliver_pkg()
{
    cp "${BUILD_DIR}/"*.deb "./"
    chown "$(id -u):$(id -g)" "./"*.deb
}

run_tests()
{
    run_script "./test/prepare_disk.sh" "${BUILD_DIR}/${TOOLBOX_IMAGE}"
    run_script "./test/start_update.sh" "${BUILD_DIR}/${TOOLBOX_IMAGE}"
    run_script "./test/toolbox_image.sh" "${BUILD_DIR}/${TOOLBOX_IMAGE}"
    run_script "./test/update_files.sh" "${BUILD_DIR}/${TOOLBOX_IMAGE}"
}

usage()
{
cat <<-EOT
    Usage: ${0} [OPTIONS]
        -c   Skip run of build environment checks
        -h   Print usage
        -t   Skip run of rootfs tests
EOT
}

trap cleanup EXIT

while getopts ":cht" options; do
    case "${options}" in
    c)
        run_env_check="no"
        ;;
    h)
        usage
        exit 0
        ;;
    t)
        run_tests="no"
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

setup_emulation_support

if command -V docker; then
    update_docker_image
fi

if [ "${run_env_check}" = "yes" ]; then
    env_check
fi

run_build

if [ "${run_tests}" = "yes" ]; then
    run_tests
fi

deliver_pkg

exit 0
