#!/bin/sh

set -eu

RESULT=0

check_precondition()
{
    local CMD="${1}"
    command -V "${CMD}" || RESULT=1
}

echo "Checking build environment preconditions:"

check_precondition debootstrap
check_precondition debootstrap
check_precondition qemu-arm-static
check_precondition dd
check_precondition mkfs.ext4
check_precondition touch
check_precondition chroot

exit "${RESULT}"
