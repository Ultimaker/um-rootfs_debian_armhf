#!/bin/sh

set -eu

CI_REGISTRY_IMAGE="${CI_REGISTRY_IMAGE:-registry.gitlab.com/ultimaker/embedded/platform/um-update_toolbox_armhf}"
CI_REGISTRY_IMAGE_TAG="${CI_REGISTRY_IMAGE_TAG:-latest}"

ARCH="${ARCH:-armhf}"
ARM_EMU_BIN=
CUR_DIR=$(pwd)
BUILD_DIR="${CUR_DIR}/.build_${ARCH}"
ROOTFS_IMG="rootfs.xz.img"

DOCKER_WORK_DIR="${DOCKER_WORK_DIR:-/build}"
DOCKER_BUILD_DIR="${DOCKER_WORK_DIR}/.build_${ARCH}"

ARMv7_MAGIC="7f454c4601010100000000000000000002002800"

run_env_check="yes"
run_tests="yes"


cleanup()
{
    unset ARM_EMU_BIN
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
        exit 1
    fi

    export ARM_EMU_BIN
}

run_in_docker()
{
    work_dir="${1}"
    script="${2}"
    args="${3}"

    docker run \
        --rm \
        --privileged \
        -e "ARM_EMU_BIN=${ARM_EMU_BIN}" \
        -v "${ARM_EMU_BIN}:${ARM_EMU_BIN}:ro" \
        -v "$(pwd):${DOCKER_WORK_DIR}" \
        -w "${work_dir}" \
        "${CI_REGISTRY_IMAGE}:${CI_REGISTRY_IMAGE_TAG}" \
        "${script}" "${args}"
}

env_check()
{
    if command -V docker; then
        run_in_docker "${DOCKER_WORK_DIR}" "./tests/buildenv.sh" ""
    else
        ./tests/buildenv.sh
    fi
}

run_build()
{
    if command -V docker; then
        run_in_docker "${DOCKER_WORK_DIR}" "./build.sh" ""
    else
        ./build.sh
    fi
}

run_tests()
{
    if command -V docker; then
        run_in_docker "${DOCKER_WORK_DIR}" "./tests/rootfs.sh" "${DOCKER_BUILD_DIR}/${ROOTFS_IMG}"
    else
        ./tests/rootfs.sh "${BUILD_DIR}/${ROOTFS_IMG}"
    fi
}

usage()
{
cat <<-EOT
    Usage: ${0} [OPTIONS]
        -c   Skip run of build environment checks
        -h   Print usage
        -t   Skip run of rootfs tests
    NOTE: This script requires root permissions to run.
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

if [ "${run_env_check}" = "yes" ]; then
    env_check
fi

if [ "${run_tests}" = "yes" ]; then
    run_build
    run_tests
else
    run_build
fi

exit 0
