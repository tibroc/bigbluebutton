# Learning analytics dashboard: the static build of the bbb-learning-dashboard package. Not a
# service: the result holds only the built app and the package's nginx fragment, which the nginx
# image (docker/nginx) copies and serves.
#
# Build with bake (docker/bake/learning-dashboard.hcl) or with podman:
#   podman build bbb-learning-dashboard
#
# Steps as in build/packages-template/bbb-learning-dashboard/build.sh: `npm ci` with the
# devDependencies (webpack lives there) and `npm run build`.

# node:24.22.0-slim (package.json engines: node >= 24)
FROM docker.io/library/node@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5 AS build

WORKDIR /src

COPY package.json package-lock.json ./
RUN npm ci

# The files the webpack build reads (webpack.config.js, postcss.config.js, tailwind.config.js),
# not a local node_modules or build directory.
COPY webpack.config.js postcss.config.js tailwind.config.js ./
COPY public public
COPY src src
RUN npm run build \
    && chmod -R a+rX,go-w build

# The app is not at its bare-metal path (/var/bigbluebutton/learning-dashboard): there the
# containers mount the bbb-data volume, which holds only the JSON files bbb-web writes.
FROM scratch
COPY --from=build /src/build /usr/share/bigbluebutton/learning-dashboard
COPY --chmod=0644 learning-dashboard.nginx /usr/share/bigbluebutton/nginx/learning-dashboard.nginx
