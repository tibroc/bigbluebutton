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

WORKDIR /src

COPY package.json package-lock.json ./
RUN CI=true npm ci

# build.sh: npm build. The settings.yml edits below come after it (on the copy webpack puts
# into dist/private, CopyPlugin in webpack.config.js; the bundles do not read the file), so that
# a new build identifier or release does not rebuild the client.
COPY . .
RUN DISABLE_ESLINT_PLUGIN=true npm run build-safari && npm run build

# Client build identifier, as in build.sh: COMMIT_DATE if set (bake variable COMMIT_DATE,
# docker/README.md "Building"), else the numeric BUILD (0 if neither is set).
ARG COMMIT_DATE=""
ARG BUILD=""
# After the ARGs: hadolint 2.15 forgets a SHELL that comes before an ARG.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# DL3022: bbb-config is a named build context (./bigbluebutton-config), not a stage.
# hadolint ignore=DL3022
COPY --from=bbb-config bigbluebutton-release /tmp/bigbluebutton-release

# build.sh: settings.yml build id, safari bundle renaming and the ?v= cache buster.
# after-install.sh: public.app.bbbServerVersion from /etc/bigbluebutton/bigbluebutton-release
# (bbb-config). sed instead of upstream's `yq-go e -i`, which would rewrite the whole file's
# formatting.
# These edits come after webpack has written the precompressed .gz copies (CompressionPlugin in
# webpack.config.js), and bbb-html5.nginx.static serves those copies (gzip_static on): each .gz
# whose content no longer matches its file is written again, so browsers get the build
# identifier as cache buster (.gz files without a sibling, the renamed safari bundles, are left
# alone). The build fails if a placeholder is left in a served file (the JS bundles keep their
# own built-in defaults, which settings.yml overrides).
WORKDIR /src/dist
RUN CLIENT_BUILD="${COMMIT_DATE:-$((BUILD))}" \
    && sed -i "s/HTML5_CLIENT_VERSION/${CLIENT_BUILD}/g" private/config/settings.yml \
    && BBB_FULL_VERSION="$(sed -n '/^BIGBLUEBUTTON_RELEASE/{s/.*=//;p}' /tmp/bigbluebutton-release | tail -n 1)" \
    && sed -i "s/^\(    bbbServerVersion: \)HTML5_FULL_BBB_VERSION\$/\1${BBB_FULL_VERSION}/" private/config/settings.yml \
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
    && find . -type f -name '*.gz' | while IFS= read -r gz; do \
         f="${gz%.gz}"; \
         if [ -f "$f" ] && ! gzip -dc "$gz" | cmp -s - "$f"; then \
           gzip -9 -n -c "$f" >"$gz" || exit 1; \
         fi; \
       done \
    && left="$(find . -type f \( \
                 \( -name '*.gz' -exec sh -c 'gzip -dc "$1" | grep -qF "?v=VERSION"' _ {} \; \) \
                 -o \( ! -name '*.gz' -exec grep -qF '?v=VERSION' {} \; \) \) -print)" \
    && if grep -q 'HTML5_CLIENT_VERSION\|HTML5_FULL_BBB_VERSION' private/config/settings.yml; then \
         left="$left private/config/settings.yml"; fi \
    && if gzip -dc private/config/settings.yml.gz | grep 'HTML5_CLIENT_VERSION\|HTML5_FULL_BBB_VERSION' >/dev/null; then \
         left="$left private/config/settings.yml.gz"; fi \
    && if [ -n "$left" ]; then \
         echo "html5 client: version placeholder left in:$left" >&2; exit 1; \
       fi \
    && chmod -R a+rX,go-w /src/dist

FROM scratch
COPY --from=build /src/dist /usr/share/bigbluebutton/html5-client
