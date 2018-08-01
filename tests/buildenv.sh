#!/bin/sh

set -eu

ARM_EMU_BIN="${ARM_EMU_BIN:-}"
BINFMT_MISC="${BINFMT_MISC:-/proc/sys/fs/binfmt_misc/}"
PACKAGES="apk mksquashfs xz"
FILESYSTEMS="overlay squashfs tmpfs"

ARMv7_MAGIC="7f454c4601010100000000000000000002002800"

result=0


check_emulation_support()
{
    # The intention of this script is not to fix a system, just to test if
    # things work. To be able to test and find the emulation support we need
    # to query the BINFMT_MISC filesystem. It is expected that this is mounted
    # on a normal system where for example qemu-arm was installed. It is however
    # valid and functional to not have this partition mounted. For example
    # alpine or docker do not do this even though the host kernel has emulation
    # working fine.
    if [ "$(id -u)" -eq 0 ]; then
        BINFMT_MISC="$(mktemp -d)"
        mount -o ro -t binfmt_misc none "${BINFMT_MISC}"
    fi

    printf "binfmt_misc support: "
    grep "enabled" "${BINFMT_MISC}/status" || { result=1; echo "disabled"; }

    printf "ARMv7 interpreter: "
    for emu in "${BINFMT_MISC}"/*; do
        if [ ! -r "${emu}" ]; then
            continue
        fi

        if grep -q "${ARMv7_MAGIC}" "${emu}"; then
            __ARM_EMU_BIN="$(grep "interpreter" "${emu}")"
            __ARM_EMU_BIN="${__ARM_EMU_BIN#interpreter }"
            break
        fi
    done

    if [ "$(id -u)" -eq 0 ]; then
        umount "${BINFMT_MISC}"
        rmdir "${BINFMT_MISC}"
    fi

    if [ ! -x "${__ARM_EMU_BIN}" ]; then
        echo "unavailable"
        echo "No kernel support, please register a valid ARMv7 interpreter."
        result=1
        return
    fi

    if [ ! -x "${ARM_EMU_BIN}" ]; then
        echo "missing"
        echo "Please set ARM_EMU_BIN to a valid interpreter, such as '${__ARM_EMU_BIN}'."
        result=1
        return
    fi

    if [ "${ARM_EMU_BIN}" != "${__ARM_EMU_BIN}" ]; then
        echo "incompatible"
        echo "ARM_EMU_BIN does not match the found interpreter. (${ARM_EMU_BIN} != ${__ARM_EMU_BIN})"
        result=1
        return
    fi
}

check_filesystem_support()
{
    for fs in ${FILESYSTEMS}; do
        if grep -q "${fs}" "/proc/filesystems"; then
            echo "${fs} support: ok"
        else
            result=1
            echo "${fs} support: error"
        fi

    done
}

check_package_installation()
{
    for pkg in ${PACKAGES}; do
        PATH="${PATH}:/sbin:/usr/sbin:/usr/local/sbin" command -V "${pkg}" || result=1
    done
}

echo "Checking build environment preconditions:"
check_package_installation
check_filesystem_support
check_emulation_support

if [ "${result}" -ne 0 ]; then
    echo "ERROR: Missing preconditions, cannot continue."
    exit 1
fi

echo "All Ok"

exit 0
