#!/bin/sh

set -eu

PACKAGES="apk mksquashfs qemu-arm xz"
FILESYSTEMS="ext4 overlay squashfs tmpfs"

result=0

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
        command -V "${pkg}" || result=1
    done
}

echo "Checking build environment preconditions:"
check_package_installation
check_filesystem_support

if [ "${result}" -ne 0 ]; then
	echo "ERROR: Missing preconditions, cannot continue."
	exit 1
fi

echo "All Ok"

exit 0
