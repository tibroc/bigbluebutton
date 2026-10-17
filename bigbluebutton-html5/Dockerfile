# html5 client: the static build of the bbb-html5 package. Not a service: the result holds only
# /usr/share/bigbluebutton/html5-client, which the nginx image (docker/nginx) copies and serves.
#
# Build with bake (docker/bake/html5-client.hcl) or with podman:
#   podman build --build-context bbb-config=bigbluebutton-config bigbluebutton-html5
#
# Steps as in build/packages-template/bbb-html5/build.sh and after-install.sh; see the
# comments below for the lines each step follows.

# node:24.22.0-slim (package.json engines: node >= 24)
FROM docker.io/library/node@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5 AS build

# Client build identifier, as in build.sh: COMMIT_DATE if set, else the numeric BUILD (0 if
# neither is set).
ARG COMMIT_DATE=""
ARG BUILD=""

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /src

COPY package.json package-lock.json ./
RUN CI=true npm ci

COPY . .
# DL3022: bbb-config is a named build context (./bigbluebutton-config), not a stage.
# hadolint ignore=DL3022
COPY --from=bbb-config bigbluebutton-release /tmp/bigbluebutton-release

# build.sh: settings.yml build id and npm build.
# after-install.sh: public.app.bbbServerVersion from /etc/bigbluebutton/bigbluebutton-release
# (bbb-config). sed instead of upstream's `yq-go e -i`, which would rewrite the whole file's
# formatting.
RUN CLIENT_BUILD="${COMMIT_DATE:-$((BUILD))}" \
    && sed -i "s/HTML5_CLIENT_VERSION/${CLIENT_BUILD}/g" private/config/settings.yml \
    && BBB_FULL_VERSION="$(sed -n '/^BIGBLUEBUTTON_RELEASE/{s/.*=//;p}' /tmp/bigbluebutton-release | tail -n 1)" \
    && sed -i "s/^\(    bbbServerVersion: \)HTML5_FULL_BBB_VERSION\$/\1${BBB_FULL_VERSION}/" private/config/settings.yml \
    && DISABLE_ESLINT_PLUGIN=true npm run build-safari && npm run build

# build.sh: safari bundle renaming and the ?v= cache buster.
WORKDIR /src/dist
RUN CLIENT_BUILD="${COMMIT_DATE:-$((BUILD))}" \
    && HASH="$(find . -maxdepth 1 -name 'bundle.*.js' -printf '%f\n' | grep -Eo 'bundle\.[a-f0-9]{20}\.js' | head -n 1 | grep -Eo '[a-f0-9]{20}' || true)" \
    && if [ -z "$HASH" ]; then \
         echo "Bundle hash not found."; \
       else \
         for FILE in *.safari.js *.safari.js.map; do \
           if [[ "$FILE" == *"$HASH"* ]]; then continue; fi; \
           PREFIX="${FILE%%.safari.js*}"; \
           SUFFIX="${FILE#*.safari.js}"; \
           mv "$FILE" "${PREFIX}.${HASH}.safari.js${SUFFIX}"; \
         done; \
       fi \
    && sed -i "s/?v=VERSION/?v=${CLIENT_BUILD}/g" index.html stylesheets/fonts.css \
    && chmod -R a+rX,go-w /src/dist

FROM scratch
COPY --from=build /src/dist /usr/share/bigbluebutton/html5-client
