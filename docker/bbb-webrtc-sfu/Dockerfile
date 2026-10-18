# bbb-webrtc-sfu as BigBlueButton packages it (bbb-webrtc-sfu): the version pinned in
# bbb-webrtc-sfu.placeholder.sh, installed like build/packages-template/bbb-webrtc-sfu/build.sh
# and configured like its after-install.sh (configure.sh). In BigBlueButton 4.0 the SFU is
# LiveKit's controller; its FreeSWITCH adapter is removed.
#
# Build with bake (docker/bake/bbb-webrtc-sfu.hcl defines the named contexts):
#   docker buildx bake -f docker-bake.hcl $(printf -- '-f %s ' docker/bake/*.hcl) bbb-webrtc-sfu
# or with podman (--format docker keeps the HEALTHCHECK):
#   podman build --format docker \
#       --build-context entrypoint-lib=docker/lib \
#       --build-context bbb-yq-go=build/packages-template/bbb-yq-go \
#       -t bbb-webrtc-sfu docker/bbb-webrtc-sfu

# node:24-slim (the package depends on nodejs 24, build/packages-template/bbb-webrtc-sfu/build.sh)
FROM docker.io/library/node@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5 AS build

ARG TARGETARCH
# Keep in sync with bbb-webrtc-sfu.placeholder.sh; the tag must resolve to this commit.
ARG BBB_WEBRTC_SFU_VERSION=v2.25.0-beta.3
ARG BBB_WEBRTC_SFU_COMMIT=88cb1a9a1c1cd1ab30ad9a131998cb91ec07980c

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Build tools only; this stage is not part of the image. git fetches the git dependencies,
# python3/make/g++ build the mediasoup worker.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl g++ git make python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git -c advice.detachedHead=false clone --branch "$BBB_WEBRTC_SFU_VERSION" --depth 1 \
        https://github.com/bigbluebutton/bbb-webrtc-sfu bbb-webrtc-sfu \
    && commit="$(git -C bbb-webrtc-sfu rev-parse HEAD)" \
    && { [ "$commit" = "$BBB_WEBRTC_SFU_COMMIT" ] || { \
        echo "$BBB_WEBRTC_SFU_VERSION is $commit, expected $BBB_WEBRTC_SFU_COMMIT" >&2; exit 1; }; }

# Dependencies as in build.sh (`npm install --production`), but exactly as locked:
# package-lock.json pins every package by integrity hash or git commit. The mediasoup worker
# is built from source (its meson subprojects are checked against their wrap hashes) instead
# of downloading a prebuilt binary. The removed directories are build.sh's.
WORKDIR /build/bbb-webrtc-sfu
ENV MEDIASOUP_SKIP_WORKER_PREBUILT_DOWNLOAD=true
RUN npm ci --omit=dev --foreground-scripts \
    && npm cache clean --force \
    && test -x node_modules/mediasoup/worker/out/Release/mediasoup-worker \
    && rm -rf node_modules/mediasoup/worker/out/Release/subprojects \
    && rm -rf node_modules/mediasoup/worker/out/Release/mediasoup-worker.p \
    && rm -rf node_modules/mediasoup/worker/out/Release/deps \
    && rm -rf .git

# yq as upstream packages it (bbb-yq-go): version from its build.sh, verified against its
# checksum file (amd64 only, like upstream). Used at build time only.
# DL3022: bbb-yq-go is a named build context, not a stage.
# hadolint ignore=DL3022
COPY --from=bbb-yq-go build.sh bbb-yq-go.sha256sum /build/yq/
WORKDIR /build/yq
RUN if [ "$TARGETARCH" != "amd64" ]; then \
        echo "upstream bbb-yq-go.sha256sum only covers amd64, not $TARGETARCH" >&2; exit 1; \
    fi \
    && yq_version="$(sed -n 's/^YQ_VERSION=//p' build.sh)" \
    && curl -fsSLO "https://github.com/mikefarah/yq/releases/download/v${yq_version}/yq_linux_amd64" \
    && grep ' yq_linux_amd64$' bbb-yq-go.sha256sum | sha256sum -c - \
    && install -m 0755 yq_linux_amd64 /usr/local/bin/yq

COPY configure.sh /build/configure.sh
RUN bash /build/configure.sh /build/bbb-webrtc-sfu \
    && chmod -R a+rX,go-w /build/bbb-webrtc-sfu


# node:24-slim
FROM docker.io/library/node@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5

COPY --from=build /build/bbb-webrtc-sfu /usr/local/bigbluebutton/bbb-webrtc-sfu
# The helpers' directory is created first, traversable by any UID (docker/README.md).
RUN install -d -m 0755 /usr/local/lib/bbb
# DL3022: entrypoint-lib is a named build context, not a stage.
# hadolint ignore=DL3022
COPY --from=entrypoint-lib --chmod=0644 entrypoint-lib.sh /usr/local/lib/bbb/entrypoint-lib.sh
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY --chmod=0644 healthcheck.js /usr/local/lib/bbb/bbb-webrtc-sfu-healthcheck.js

# Mount point of the Tier 3 override production.yml (read only).
RUN install -d -m 0755 /etc/bigbluebutton/bbb-webrtc-sfu

# As the bare-metal unit (bbb-webrtc-sfu.service).
ENV NODE_ENV=production \
    NODE_CONFIG_DIR=/etc/bigbluebutton/bbb-webrtc-sfu/:/usr/local/bigbluebutton/bbb-webrtc-sfu/config/ \
    ALLOW_CONFIG_MUTATIONS=true
# Container wiring (node-config environment variables): LiveKit controller on, compose
# service names, client WebSocket reachable from nginx.
ENV LIVEKIT_ENABLED=true \
    LIVEKIT_HOST=http://livekit:7880 \
    REDIS_HOST=redis \
    CLIENT_HOST=0.0.0.0

WORKDIR /usr/local/bigbluebutton/bbb-webrtc-sfu
USER 998:998
# 3008 client WebSocket (clientPort, proxied by nginx); 3040 LiveKit webhook receiver.
EXPOSE 3008/tcp 3040/tcp
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
    CMD ["node", "/usr/local/lib/bbb/bbb-webrtc-sfu-healthcheck.js"]
ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "server.js"]
