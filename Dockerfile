FROM registry.hub.docker.com/library/alpine:latest

LABEL Maintainer="software-embedded-platform@ultimaker.com" \
      Comment="Ultimaker update-tools filesystem"

RUN apk add --no-cache \
        qemu-arm \
        squashfs-tools \
        xz \
    && \
    rm -f /var/cache/apk/* && \
    ln -sf /usr/bin/qemu-arm /usr/bin/qemu-arm-static

COPY tests/buildenv.sh /tests/buildenv.sh
