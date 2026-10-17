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
| `docker/tests/` | tests: helper, UID/GID check, lint, golden files, compose, smoke |
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

The CI workflow `.github/workflows/build-docker-image.yml` lists `docker/bake/*.hcl` itself, so
adding an image means adding its bake file, one line in the `default` group in
`docker-bake.hcl` (bake does not merge a group defined in several files: the last definition
wins) and its job in `build-all-images.yml`.

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
# hadolint ignore=DL3022
COPY --from=entrypoint-lib --chmod=0644 entrypoint-lib.sh /usr/local/lib/bbb/entrypoint-lib.sh
```

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
