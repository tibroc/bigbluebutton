# Container images for BigBlueButton

Images are built from this repository. A component with its own source directory has its
`Dockerfile` there (`<component>/Dockerfile`, image files in `<component>/docker/`). Images
without a source directory live in `docker/<name>/`.

| Path | Contents |
|---|---|
| `docker-bake.hcl` | shared bake definitions: metadata target, `entrypoint-lib` context, Java base, `default` group |
| `docker/bake/<image>.hcl` | the bake target(s) of one image |
| `docker/java-base/` | Java 21 runtime base for the JVM images |
| `docker/lib/` | shared entrypoint helper (`entrypoint-lib.sh`, see `docker/lib/README.md`) |
| `docker/tests/` | tests: helper, UID/GID check, directory modes, BuildKit build, lint, golden files, compose, smoke |
| `docker/.hadolint.yaml` | hadolint rules for all Dockerfiles |

## Building

Each image's targets are in their own file, `docker/bake/<image>.hcl`. `docker-bake.hcl` holds
only what images share. Bake reads several files when `-f` is repeated and combines them into one
definition ([`docker buildx bake --file`](https://docs.docker.com/reference/cli/docker/buildx/bake/#file)),
so always pass the root file and every per-image file:

```bash
docker buildx bake -f docker-bake.hcl $(printf -- '-f %s ' docker/bake/*.hcl) web
docker buildx bake -f docker-bake.hcl $(printf -- '-f %s ' docker/bake/*.hcl) --print   # all targets
```

or, equivalently, with [`BUILDX_BAKE_FILE`](https://docs.docker.com/build/building/variables/#buildx_bake_file)
(paths separated by `:`; ignored when `-f` is given):

```bash
export BUILDX_BAKE_FILE="$(printf '%s\n' docker-bake.hcl docker/bake/*.hcl | paste -sd:)"
docker buildx bake web
```

Do not rely on bake's default file lookup: it also loads `docker-compose.yml` from the
repository root and merges its services into the definition
([file lookup](https://docs.docker.com/build/bake/reference/#file-format)).

Adding an image means adding its bake file (with `platforms`, see [CI](#ci)) and one line in
the `default` group in `docker-bake.hcl` (bake does not merge a group defined in several files:
the last definition wins). CI picks it up from there.

### Image names

`docker-compose.yml` runs `${BBB_IMAGE_REGISTRY}/bbb-<image>:${BBB_IMAGE_TAG}` (defaults
`ghcr.io/bigbluebutton` and `4.0.1`, see `docker/config-contract.yaml`). Bake tags local builds
the same way, with the bake variables `BBB_IMAGE_REGISTRY` (default `localhost`) and
`BBB_IMAGE_TAG` (default `4.0.1`). In CI the tags of docker/metadata-action replace them.

| Bake target | Image | Compose service |
|---|---|---|
| `apps-akka` | `bbb-apps-akka` | `akka-apps` |
| `bbb-webrtc-sfu` | `bbb-webrtc-sfu` | `bbb-webrtc-sfu` |
| `certbot` | `bbb-certbot` | `certbot` |
| `coturn` | `bbb-coturn` | `coturn` |
| `db-init` | `bbb-db-init` | `db-init` |
| `graphql-actions` | `bbb-graphql-actions` | `graphql-actions` |
| `graphql-middleware` | `bbb-graphql-middleware` | `graphql-middleware` |
| `graphql-server` | `bbb-graphql-server` | `graphql-server` |
| `haproxy` | `bbb-haproxy` | `haproxy` |
| `livekit` | `bbb-livekit` | `livekit` |
| `nginx` | `bbb-nginx` | `nginx` |
| `postgres` | `bbb-postgres` | `postgres` |
| `shared-notes` | `bbb-shared-notes` | `shared-notes` |
| `web` | `bbb-web` | `bbb-web` |
| `export-annotations` | `bbb-export-annotations` | not in the skeleton yet; image not yet reworked (Node 22, golden case not run yet) |
| `record-and-playback` | `bbb-record-and-playback` | not in the skeleton yet |
| `html5-client` | `bbb-html5-client` | none: build stage of `nginx` |
| `learning-dashboard` | `bbb-learning-dashboard` | none: build stage of `nginx` |

`bbb-common-message`, `bbb-common-web` and `_java-base` are build stages and get no tag.
Third-party images (redis) are pinned by tag and digest in `docker-compose.yml`.

To run the stack on local builds:

```bash
docker buildx bake -f docker-bake.hcl $(printf -- '-f %s ' docker/bake/*.hcl) --load
BBB_IMAGE_REGISTRY=localhost docker compose up -d     # or set it in .env
```

### Shared entrypoint helper

Every image gets `docker/lib/entrypoint-lib.sh` the same way: its bake target inherits
`_entrypoint-lib`, which defines the named context `entrypoint-lib` (`./docker/lib`), and its
Dockerfile copies the helper from that context:

```hcl
target "web" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context  = "./bigbluebutton-web"
}
```

```dockerfile
RUN install -d -m 0755 /usr/local/lib/bbb
# hadolint ignore=DL3022
COPY --from=entrypoint-lib --chmod=0644 entrypoint-lib.sh /usr/local/lib/bbb/entrypoint-lib.sh
```

Create every directory that a `COPY --chmod` writes into before the `COPY`, with
`install -d -m 0755`: BuildKit gives the directories it creates for the `COPY` the `--chmod`
mode too, so with `0644` no other user can enter them (podman/buildah creates them with
`0755`). `docker/tests/dirmodes/check.sh IMAGE` finds such directories, and
`docker/tests/buildkit/build.sh TARGET` builds with BuildKit on a host that has only podman.

Images built on the Java base already contain the helper at that path. Without bake, pass the
context directly: `podman build --build-context entrypoint-lib=docker/lib ...` (or
`docker buildx build --build-context entrypoint-lib=docker/lib ...`).

### Java base

`docker/java-base/` is `ubuntu:24.04` (pinned by digest) with Ubuntu's `openjdk-21-jre-headless`,
the OpenJDK that bare-metal installs use, plus the entrypoint helper. `JAVA_HOME` is
`/usr/lib/jvm/java-21` on every architecture. It contains nothing that only one image needs:
such tools (ImageMagick, poppler, ...) go into that image. JVM images use it as a named context:

```hcl
contexts = { java-base = "target:_java-base" }
```

```dockerfile
# hadolint ignore=DL3006
FROM java-base
```

### Package versions

Base images are pinned by digest, with the tag in a comment. apt/apk packages are not pinned
individually: the digest-pinned base is the reproducibility anchor, and each image's installed
package versions are recorded at build time (SBOM). hadolint DL3008/DL3018 are therefore ignored
in `docker/.hadolint.yaml`.

## Running the stack

`docker-compose.yml` at the repository root is the only compose file. It is static: settings
come from `.env` (template: `.env.sample`, generated from `docker/config-contract.yaml`) and
each service receives only the variables it reads. The images validate them at start and exit
with a message naming a missing or malformed variable.

- **Walking skeleton.** The file has the services of the skeleton: haproxy, certbot, nginx,
  bbb-web, akka-apps, graphql-server, graphql-middleware, graphql-actions, shared-notes, redis,
  postgres, db-init (a job that exits after setting up the databases), livekit, bbb-webrtc-sfu
  and coturn. Recording, export-annotations, office conversion, webhooks, greenlight,
  monitoring, setup and preflight follow; until then use `BBB_FEATURES=recording` or an empty
  `BBB_FEATURES` (with `webhooks`, nginx would proxy to a service that does not exist yet).
- **Restart nginx after recreating or restarting an upstream.** nginx resolves the service
  names it proxies to once, at start, so it waits for all of them to be healthy. `docker
  compose up -d` recreates only the services whose configuration or image changed; if that
  included one of nginx's upstreams (bbb-web, shared-notes, graphql-server, graphql-middleware,
  livekit, bbb-webrtc-sfu), run `docker compose restart nginx` afterwards, or nginx answers 502
  for it (or proxies to whichever container now has the old address). The same applies after
  `docker compose restart` and after an upstream restarted by itself: Docker Engine 29 gives
  restarted containers other addresses, and `docker compose restart` restarts all services at
  once, in no particular order. Restart nginx once the others are healthy.
- **Ports.** Only nginx 80/tcp, haproxy 443/tcp, livekit 7882/udp and coturn 3478/udp+tcp are
  published. haproxy and nginx run as non-root users and bind 443, 80 and 81 through the
  per-container sysctl `net.ipv4.ip_unprivileged_port_start=0`. Published ports bypass ufw and
  firewalld.
- **Read-only root filesystems.** Every service runs with `read_only: true`. Each writes only to
  its volumes and to tmpfs mounts at `/tmp` and the directories its entrypoint renders into
  (Kubernetes: `emptyDir`).

### Override files (Tier 3)

Tier 3 files keep their bare-metal paths (`docker/config-contract.yaml`, `overrides`). Mount
them in `docker-compose.override.yml` next to `docker-compose.yml`, which Docker Compose reads
automatically, for example:

```yaml
services:
  bbb-web:
    volumes:
      - /etc/bigbluebutton/bbb-web.properties:/etc/bigbluebutton/bbb-web.properties:ro
```

The akka-apps image ships `/etc/bigbluebutton/bbb-html5.yml`, the html5 client settings
override, with the content `{}` (bare metal always has this file; without it akka-apps logs an
error at every start). To use your own file, mount it over the shipped one:

```yaml
services:
  akka-apps:
    volumes:
      - /etc/bigbluebutton/bbb-html5.yml:/etc/bigbluebutton/bbb-html5.yml:ro
```

Compose `configs:` with inline `content:` cannot be used here: Docker Compose writes such a config
into the container at start, which fails on the read-only root filesystem (RB-04, 2026-10-18).

## Testing the stack with Docker Engine

Docker and podman differ in details that break images at run time (the embedded DNS server,
tmpfs mounted `noexec`, `configs:`, what `docker compose restart` does). `docker/tests/stack/`
runs the stack with Docker Engine 29.9.1 on a host that has only podman, and tests the join path
of a browser:

```bash
# build the images with BuildKit, a few at a time (memory), tag 4.0.1
docker/tests/buildkit/build.sh --tag 4.0.1 haproxy certbot coturn livekit
docker/tests/buildkit/build.sh --tag 4.0.1 postgres db-init graphql-middleware graphql-actions
docker/tests/buildkit/build.sh --tag 4.0.1 graphql-server        # then apps-akka, web,
                                                                 # shared-notes, bbb-webrtc-sfu, nginx
docker/tests/stack/dind.sh start     # Docker Engine in a privileged podman container
docker/tests/stack/dind.sh load      # copies the images of docker-compose.yml from podman
docker/tests/stack/dind.sh up        # docker compose up -d --wait, certbot scaled to 0
docker/tests/stack/dind.sh test      # join-path.sh, including two restart cycles
docker/tests/stack/dind.sh compose logs akka-apps   # any docker compose command
docker/tests/stack/dind.sh stop      # removes the Engine container and all its data
```

The stack runs with `docker/tests/stack/fixture.env` (fixture values, `bbb.example.com`, the
self-signed certificate; certbot is scaled to 0, so no ACME request is made). Its ports are
published inside the Engine container only. `join-path.sh` does what the html5 client does when
a user joins: API create and join, the redirect to the client with the session token,
`/api/rest/meetingStaticData` (Hasura, authenticated through akka-apps), the GraphQL WebSocket
through graphql-middleware up to the first subscription, and the LiveKit signaling URL. Then it
runs `docker compose restart` and, as a second cycle, restarts every service while redis is
stopped; after each cycle it waits until all services are healthy, restarts nginx (see above) and
repeats the join path. It prints `STEP <name>: OK|FAIL` and exits non-zero on failure. On a
Docker host, run it directly in the directory of `docker-compose.yml`:
`BBB_SHARED_SECRET=... docker/tests/stack/join-path.sh --domain <domain> --connect-ip ''`
(add `--insecure` for a self-signed certificate; `--help` lists the options).

## Running under an arbitrary UID/GID

Every image must run under any UID/GID chosen at deploy time: Docker Compose sets
`user: "${BBB_UID}:${BBB_GID}"` for the services that write the shared data volume, and
Kubernetes may set any `runAsUser`/`runAsGroup`. The UID usually has no entry in `/etc/passwd`.

Rules for every image:

1. **No fixed user at runtime.** Do not require a named user or a particular UID. Images may set
   a numeric non-root default (`USER 998:998`), never a user name (hadolint DL3066). No `gosu`,
   `su` or `chown` at start.
2. **Writable paths are declared.** A process writes only to `/tmp`, to declared volumes, and to
   the directories its entrypoint renders into. Create each of those directories in the
   Dockerfile, writable for any UID: `install -d -m 1777 DIR` (sticky, like `/tmp`). This also
   covers volume mount points: a new named volume copies the owner and mode of the image
   directory it is mounted on. Everything else stays root-owned and read-only for the service.
3. **Files the service reads are world-readable** (`0644`, directories and scripts `0755`).
   Secrets rendered at start are written by the service's own UID with `--mode 0600`/`0640`
   (`docker/lib/README.md`).
4. **No reliance on `$HOME`.** Without a passwd entry, `HOME` is `/` (Docker) or empty
   (podman), and the JVM's `user.home` is `?` unless `HOME` is set. A component that needs a
   writable home gets `HOME=/tmp` in its image, as upstream does for its LibreOffice container
   (`bbb-libreoffice/assets/convert-local.sh`).
5. **All writers of the shared data volume** (`/var/bigbluebutton`) and the recorder volume
   (`/var/lib/bbb-webrtc-recorder`) run with the same `BBB_UID`/`BBB_GID`, so files keep one
   owner, as with the single `bigbluebutton` user on bare metal.

Check an image with `docker/tests/uid/check.sh` (docker if installed, else podman). It runs the
image as `12345:12345` without a passwd entry, with a read-only root filesystem and a tmpfs
`/tmp`, and fails on a non-zero exit or a permission error:

```bash
# entrypoint in render-only mode, plus the directories it renders into and its volumes
docker/tests/uid/check.sh --env-file docker/tests/golden/<image>/fixture.env \
    --writable /etc/bigbluebutton --volume /var/bigbluebutton <image>
# an image without an entrypoint: run a command instead
docker/tests/uid/check.sh --writable /tmp bbb-java-base:local -- java -version
```

`docker/tests/uid/sample/` is a minimal image that follows these rules; built with
`--build-arg BROKEN=1` it breaks them and the check fails.

## Lint

```bash
docker/tests/lint/run.sh                                  # every Dockerfile in the repository
docker/tests/lint/run.sh bigbluebutton-web/Dockerfile     # selected files
```

runs hadolint (pinned image) with `docker/.hadolint.yaml`. Named build contexts look like
undefined stages or untagged images to hadolint: silence DL3022 (`COPY --from=<context>`) and
DL3006 (`FROM <context>`) on those lines only, with `# hadolint ignore=...`, not globally.

## CI

Two GitHub Actions workflows build the images with BuildKit (`docker/bake-action`), as
`docker buildx bake` does for users. Both take the image list from bake: every target of the
`default` group in `docker-bake.hcl`, named after its tag (`bbb-<image>`). The BuildKit layer
cache is kept per target and platform (`type=gha`) and shared by both workflows.

**`build-all-images.yml`** builds every image for each of its platforms on a native runner
(`ubuntu-24.04`, `ubuntu-24.04-arm`) through the reusable `build-docker-image.yml`, and merges
the platform images into one multi-arch image. On pushes (branches and `v*.*.*` tags) and manual
runs it pushes `ghcr.io/<repository owner>/bbb-<image>`, which is `ghcr.io/bigbluebutton/bbb-<image>`,
the default of `docker-compose.yml`, for the upstream repository; a fork pushes to its own owner
and runs the stack with `BBB_IMAGE_REGISTRY=ghcr.io/<owner>`. Tags: the branch name (also with
a `dev-` prefix), `sha-<short sha>` and, for release tags, `<version>`, `<major>.<minor>` and
`<major>`. Pull requests that change image files build everything without pushing.

**Platforms** are set per image in `docker/bake/<image>.hcl`. An image that builds only for
amd64 sets `platforms = ["linux/amd64"]` with the reason in a comment (today graphql-server,
graphql-middleware, livekit, bbb-webrtc-sfu, shared-notes and record-and-playback); every other
image sets `platforms = compact(split(",", BBB_PLATFORMS))`. The bake variable `BBB_PLATFORMS`
is empty by default, so local builds are for the host's platform; CI sets it to
`linux/amd64,linux/arm64` to read the list:

```bash
BBB_PLATFORMS=linux/amd64,linux/arm64 \
    docker buildx bake -f docker-bake.hcl $(printf -- '-f %s ' docker/bake/*.hcl) --print default
```

A target in the `default` group without a `bbb-<image>` tag or without platforms fails the
workflow.

**`docker-checks.yml`** runs on pull requests that change files below `docker/`, `*/docker/`,
Dockerfiles, `docker-bake.hcl`, `docker-compose.yml` or the contract outputs, in parallel jobs:

| Job | Runs |
|---|---|
| Configuration contract | `docker/tests/contract/run.sh` with `docker/contract/validate.sh`, `docker/contract/generate.sh --check` and `docker/tests/contract/test-contract.sh` |
| Golden runner tests | `docker/tests/golden/run.sh` |
| Compose file | `docker/tests/compose/run.sh`, then `assert-compose.sh` on `docker-compose.yml` for every feature combination |
| Lint | `docker/tests/lint/run.sh` on the Dockerfiles the pull request changes (all of them when `docker/.hadolint.yaml` changes or on manual runs); shellcheck at severity warning on the scripts below `docker/` and `*/docker/`, including those without a `.sh` suffix |
| Image `bbb-<image>` (one per bake target, amd64) | build with BuildKit, tagged `localhost/bbb-<image>:golden` and loaded into Docker; `docker/tests/dirmodes/check.sh`; `docker/tests/golden/run-golden.sh --engine docker --parity` for the golden cases of that image; `docker/tests/uid/check.sh` with the fixture env of its golden case, a write probe for each tmpfs and each writable named volume of its service in `docker-compose.yml` (`--no-render` for images without a golden case) |

`shellcheck.yml` (upstream) also checks every `*.sh` file of the repository at severity error.
Images that are neither in `docker-compose.yml` nor in a golden case (the build stage
`html5-client` and `learning-dashboard`, and export-annotations and record-and-playback until
they join the stack) get the directory-mode check only.
