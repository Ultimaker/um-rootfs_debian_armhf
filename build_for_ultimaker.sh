#!/bin/sh

set -eu

CI_REGISTRY_IMAGE="${CI_REGISTRY_IMAGE:-registry.gitlab.com/ultimaker/embedded/platform/um-updatefs_armhf}"
CI_REGISTRY_IMAGE_TAG="${CI_REGISTRY_IMAGE_TAG:-latest}"

ARCH="${ARCH:-armhf}"
CUR_DIR=$(pwd)
BUILD_DIR="${CUR_DIR}/.build_${ARCH}"
ROOTFS_IMG="rootfs.xz.img"

DOCKER_WORK_DIR="${DOCKER_WORK_DIR:-/build}"
DOCKER_BUILD_DIR="${DOCKER_WORK_DIR}/.build_${ARCH}"

run_env_check="no"
run_tests="no"

run_in_docker()
{
    work_dir="${1}"
    script="${2}"
    args="${3}"

    docker run --rm \
        --privileged \
        -v "$(pwd):${DOCKER_WORK_DIR}" \
        -w "${work_dir}" \
        "${CI_REGISTRY_IMAGE}:${CI_REGISTRY_IMAGE_TAG}" \
        "${script}" "${args}"
}

env_check()
{
    if command -V docker; then
        run_in_docker "${DOCKER_WORK_DIR}/tests" "./buildenv.sh" ""
    else
        ./tests/buildenv.sh
    fi

}

run_build()
{
    env_check
    if command -V docker; then
        run_in_docker "${DOCKER_WORK_DIR}" "./build.sh" ""
    else
        ./build.sh
    fi
}

run_tests()
{
    env_check
    if command -V docker; then
        run_in_docker "${DOCKER_WORK_DIR}/tests" "./rootfs.sh" "${DOCKER_BUILD_DIR}/${ROOTFS_IMG}"
    else
        ./tests/rootfs.sh "${BUILD_DIR}/${ROOTFS_IMG}"
    fi
}

usage()
{
cat <<-EOT
    Usage: ${0} [OPTIONS]
        -c   Run build environment checks (run by default when building and testing)
        -h   Print usage
        -t   Run rootfs tests
    NOTE: This script requires root permissions to run.
EOT
}

while getopts ":cht" options; do
    case "${options}" in
    c)
      run_env_check="yes"
      ;;
    h)
      usage
      exit 0
      ;;
    t)
      run_tests="yes"
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


# Check build environment requirements
if [ "${run_env_check}" = "yes" ]; then
    env_check
    exit 0
fi

# Build the rootfs image
run_build

# Test the rootfs image
if [ "${run_tests}" = "yes" ]; then
    run_tests
fi

exit 0
