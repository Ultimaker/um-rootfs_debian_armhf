FROM registry.hub.docker.com/library/alpine:latest

LABEL Maintainer="software-embedded-platform@ultimaker.com" \
      Comment="Ultimaker update-tools filesystem"

RUN apk add --no-cache \
        squashfs-tools \
        xz \
    && \
    rm -f /var/cache/apk/*

COPY test/buildenv.sh /test/buildenv.sh
