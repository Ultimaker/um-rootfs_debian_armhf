#!/bin/sh

set -eux

RESULT=0

set_error()
{
    RESULT="${ERROR}"
}

are_all_build_env_preconditions_met()
{
    command -v debootstrap >/dev/null 2>&1 || { printf >&2 "Build env dependency missing: please install 'debootstrap'\n"; set_error; }
    command -v qemu-arm-static >/dev/null 2>&1 || { printf >&2 "Build env dependency missing: please install 'qemu-arm-static'\n"; set_error; }
    command -v dd >/dev/null 2>&1 || { printf >&2 "Build env dependency missing: please install 'dd'\n"; set_error; }
    command -v mkfs.ext4 >/dev/null 2>&1 || { printf >&2 "Build env dependency missing: please install 'mkfs.ext4'\n"; set_error; }
    command -v touch >/dev/null 2>&1 || { printf >&2 "Build env dependency missing: please install 'touch'\n"; set_error; }
    command -v chroot >/dev/null 2>&1 || { printf >&2 "Build env dependency missing: please install 'chroot'\n"; set_error; }
}

are_all_build_env_preconditions_met

exit "${RESULT}"
