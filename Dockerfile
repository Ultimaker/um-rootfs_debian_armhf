#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
#
# SPDX-License-Identifier: AGPL-3.0+

FROM registry.hub.docker.com/library/alpine:latest

LABEL Maintainer="software-embedded-platform@ultimaker.com" \
      Comment="Ultimaker update-tools filesystem"

RUN apk add --no-cache \
        e2fsprogs \
        f2fs-tools \
        sfdisk \
        squashfs-tools \
        util-linux \
        xz \
    && \
    rm -f /var/cache/apk/*

COPY test/buildenv.sh /test/buildenv.sh
