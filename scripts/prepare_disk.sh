#!/bin/sh
#
# SPDX-License-Identifier: AGPL-3.0+
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
#

set -eu

PARTITION_TABLE_FILE="${PARTITION_TABLE_FILE:-}"

usage()
{
    cat <<-EOT
	Usage: ${0} [OPTIONS] <DISK>
	Prepare the target DISK to a predefined disk layout.
	  -t Partition table file (mandatory).
	  -h Print this help text and exit
	NOTE: This script is destructive and will destroy your data.
EOT
}

while getopts ":t:h" options; do
    case "${options}" in
    t)
        PARTITION_TABLE_FILE="${OPTARG}"
        ;;
    h)
        usage
        exit 0
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

if [ "${#}" -ne 1 ]; then
    echo "Missing argument <disk>."
    usage
    exit 1
fi

if [ ! -r "${PARTITION_TABLE_FILE}" ]; then
    echo "Unable to read partition table file '${PARTITION_TABLE_FILE}', cannot continue."
    exit 1
fi

exit 0
