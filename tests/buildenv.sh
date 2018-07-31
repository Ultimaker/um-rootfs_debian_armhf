#!/bin/sh

set -eu

PACKAGES="apk mksquashfs qemu-arm xz"
FILESYSTEMS="ext4 overlay squashfs tmpfs"

result=0

check_filesystem_support()
{
    fs="${1}"
    grep "${fs}" "/proc/filesystems" || result=1
}

check_package_installation()
{
    cmd="${1}"
    command -V "${cmd}" || result=1
}

echo "Checking build environment preconditions:"

for pkg in ${PACKAGES}; do
    check_package_installation "${pkg}"
done

for fs in ${FILESYSTEMS}; do
    check_filesystem_support "${fs}"
done

if [ "${result}" -ne 0 ]; then
	echo "ERROR: Missing preconditions, cannot continue."
	exit 1
fi

echo "All Ok"

exit 0
