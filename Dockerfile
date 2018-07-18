FROM registry.hub.docker.com/library/debian:jessie-slim

LABEL Maintainer="software-embedded-platform@ultimaker.com" \
      Comment="Ultimaker um-rootfs_debian_armhf"

RUN apt-get update && \
    apt-get install -q -y --no-install-recommends \
    debootstrap \
    qemu-user-static \
    xz-utils && \
    rm -r /var/lib/apt/lists/*

COPY tests/buildenv.sh /tests/buildenv.sh
COPY tests/rootfs.sh /tests/rootfs.sh
COPY build.sh /build.sh
