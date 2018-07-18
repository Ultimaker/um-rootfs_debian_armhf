#!/bin/sh

set -eu

ARCH="${ARCH:-armhf}"
CUR_DIR=$(pwd)
BUILD_DIR="${CUR_DIR}/.build_${ARCH}"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
RUN_ENV_CHECK="no"
RUN_TESTS="no"

env_check()
{
    cd tests
    ./buildenv.sh
    cd "${CUR_DIR}"
}

run_tests()
{
    cd tests
    ./rootfs.sh -r "${ROOTFS_DIR}"
    cd "${CUR_DIR}"
}

usage()
{
cat <<-EOT
    Usage: ${0} [OPTIONS]
        -c   Run build environment checks
        -h   Print usage
        -t   Run rootfs tests
    NOTE: This script requires root permissions to run.
EOT
}

while getopts ":cht" options; do
  case "${options}" in
    c)
      RUN_ENV_CHECK="yes"
      ;;
    h)
      usage
      exit 0
      ;;
    t)
      RUN_TESTS="yes"
      ;;
    :)
      printf "Option -%s requires an argument.\\n" "${OPTARG}"
      exit 1
      ;;
    \?)
      printf "Invalid option: -%s\\n" "${OPTARG}"
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"


# Check build environment requirements
if [ "${RUN_ENV_CHECK}" = "yes" ]; then
    env_check
fi

# Build the rootfs image
./build.sh

# Test the rootfs image
if [ "${RUN_TESTS}" = "yes" ]; then
    run_tests
fi

exit 0
