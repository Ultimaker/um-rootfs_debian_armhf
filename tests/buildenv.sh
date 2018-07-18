#!/bin/sh

set -eux

RESULT=0

check_precondition()
{
    local CMD="${1}"
    command -V "${CMD}" || (printf "Missing: %s\\n" "${CMD}"; RESULT=1;)
}

printf "Checking build environment preconditions:\\n"

check_precondition debootstrap
check_precondition debootstrap
check_precondition qemu-arm-static
check_precondition dd
check_precondition mkfs.ext4
check_precondition touch
check_precondition chroot

exit "${RESULT}"
