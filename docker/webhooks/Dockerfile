# bbb-webhooks as BigBlueButton packages it (bbb-webhooks): the version pinned in
# bbb-webhooks.placeholder.sh, installed like build/packages-template/bbb-webhooks/build.sh and
# configured like its after-install.sh (configure.sh). Optional, as on bare metal: compose
# profile `webhooks`.
#
# Build with bake (docker/bake/webhooks.hcl defines the named contexts):
#   docker buildx bake -f docker-bake.hcl $(printf -- '-f %s ' docker/bake/*.hcl) webhooks
# or with podman (--format docker keeps the HEALTHCHECK):
#   podman build --format docker \
#       --build-context entrypoint-lib=docker/lib \
#       --build-context bbb-yq-go=build/packages-template/bbb-yq-go \
#       -t bbb-webhooks docker/webhooks

# node:24-slim (the package depends on nodejs 24, build/packages-template/bbb-webhooks/build.sh)
FROM docker.io/library/node@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5 AS build

ARG TARGETARCH
# Keep in sync with bbb-webhooks.placeholder.sh; the tag must resolve to this commit.
ARG BBB_WEBHOOKS_VERSION=v3.7.0
ARG BBB_WEBHOOKS_COMMIT=9787aea9756c02bb0d32090b601afed0c281f461

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Build tools only; this stage is not part of the image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git -c advice.detachedHead=false clone --branch "$BBB_WEBHOOKS_VERSION" --depth 1 \
        https://github.com/bigbluebutton/bbb-webhooks bbb-webhooks \
    && commit="$(git -C bbb-webhooks rev-parse HEAD)" \
    && { [ "$commit" = "$BBB_WEBHOOKS_COMMIT" ] || { \
        echo "$BBB_WEBHOOKS_VERSION is $commit, expected $BBB_WEBHOOKS_COMMIT" >&2; exit 1; }; } \
    && rm -rf bbb-webhooks/.git

# Dependencies as in build.sh (`npm ci --omit=dev`), which also installs the whole source tree
# without .git.
WORKDIR /build/bbb-webhooks
RUN npm ci --omit=dev \
    && npm cache clean --force

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
RUN bash /build/configure.sh /build/bbb-webhooks \
    && chmod -R a+rX,go-w /build/bbb-webhooks


# node:24-slim
FROM docker.io/library/node@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5

COPY --from=build /build/bbb-webhooks /usr/local/bigbluebutton/bbb-webhooks
# The helpers' directory is created first, traversable by any UID (docker/README.md).
RUN install -d -m 0755 /usr/local/lib/bbb
# DL3022: entrypoint-lib is a named build context, not a stage.
# hadolint ignore=DL3022
COPY --from=entrypoint-lib --chmod=0644 entrypoint-lib.sh /usr/local/lib/bbb/entrypoint-lib.sh
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY --chmod=0644 healthcheck.js /usr/local/lib/bbb/bbb-webhooks-healthcheck.js

# Mount point of the Tier 3 override production.yml (read only). The application sets
# NODE_CONFIG_DIR itself: /etc/bigbluebutton/bbb-webhooks/ before <working directory>/config/
# (src/common/env.js).
RUN install -d -m 0755 /etc/bigbluebutton/bbb-webhooks

# As the bare-metal unit (bbb-webhooks.service); production.yml is only read with this NODE_ENV.
ENV NODE_ENV=production
# Container wiring (node-config environment variables): API reachable from nginx, compose
# service name of redis.
ENV SERVER_BIND_IP=0.0.0.0 \
    REDIS_HOST=redis

WORKDIR /usr/local/bigbluebutton/bbb-webhooks
USER 998:998
# 3005 hooks API (proxied by nginx under /bigbluebutton/api/hooks).
EXPOSE 3005/tcp
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
    CMD ["node", "/usr/local/lib/bbb/bbb-webhooks-healthcheck.js"]
ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "app.js"]
