#!/bin/sh

set -eu

PRECONDITIONS="apk cpio find git xz"

RESULT=0

check_precondition()
{
    CMD="${1}"
    command -V "${CMD}" || RESULT=1
}

echo "Checking build environment preconditions:"

for pkg in ${PRECONDITIONS}; do
    check_precondition "${pkg}"
done

exit "${RESULT}"
