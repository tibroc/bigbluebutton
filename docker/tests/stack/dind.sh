#!/usr/bin/env bash
# Run the stack of docker-compose.yml with a real Docker Engine on a host that has only podman.
# Docker differs from podman/podman-compose in details that break images at run time (embedded
# DNS, tmpfs mounted noexec, `configs:`, restart behaviour), so the stack is tested with the
# Engine the deployment uses.
#
# Usage: docker/tests/stack/dind.sh COMMAND [ARG...]
#
#   start              start the Docker Engine container (idempotent)
#   load [IMAGE...]    copy images from podman into the Engine; default: every image of the
#                      compose file (localhost/bbb-<image>:TAG, built with
#                      docker/tests/buildkit/build.sh --tag TAG). Images pinned by digest
#                      (redis) are pulled by the Engine instead.
#   up                 docker compose up -d --wait, certbot scaled to 0, then restart nginx
#   test [ARG...]      docker/tests/stack/join-path.sh against the stack (ARGs passed on)
#   compose ARG...     docker compose ARG... for the stack
#   docker ARG...      docker ARG... in the Engine
#   stop               remove the Engine container and its volume (the stack with it)
#
# Environment:
#   DIND_NAME          name of the podman container (default bbb-dind); its image store and
#                      volumes are in the podman volume DIND_NAME-data
#   BBB_IMAGE_TAG      tag of the BBB images (default 4.0.1)
#
# The Engine runs in a privileged podman container (rootless podman: privileged within the user
# namespace only) with the repository mounted read-only at /src. The stack uses
# docker/tests/stack/fixture.env (fixture values only, docs: docker/README.md "Testing"):
# images from `localhost`, the self-signed certificate of haproxy, certbot scaled to 0, so no
# ACME request is ever made. Ports are published inside the Engine container's network
# namespace only; nothing is published on the host.
#
# Exit status: that of the command; 2 on usage or engine errors.

set -euo pipefail

# docker:29.9.1-dind (multi-arch index). Docker Engine 29.9.1 is the Engine of the RB-04 VM
# (qa/results RB-04 2026-10-18; docker/tests/buildkit/build.sh uses the CLI of the same release).
DIND_IMAGE="docker.io/library/docker@sha256:3e5756e2b6dad6a5f1f5deacf0a19f9eaa2581b76ae092b2d4a118162e1d4d4e"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
NAME="${DIND_NAME:-bbb-dind}"
TAG="${BBB_IMAGE_TAG:-4.0.1}"

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0" >&2; exit 2; }
die() { echo "dind.sh: $*" >&2; exit 2; }

[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid DIND_NAME: $NAME"
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid BBB_IMAGE_TAG: $TAG"
command -v podman >/dev/null 2>&1 || die "podman not found"

running() { [ "$(podman inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || true)" = true ]; }
require_running() { running || die "the Engine container $NAME is not running (dind.sh start)"; }

# in_engine ARG...: run ARG... in the Engine container, stdin attached.
in_engine() { podman exec -i -e BBB_IMAGE_TAG="$TAG" "$NAME" "$@"; }

compose() {
    in_engine docker compose --project-directory /src -f /src/docker-compose.yml \
        --env-file /src/docker/tests/stack/fixture.env "$@"
}

start() {
    if running; then
        echo "Engine container $NAME is running"
    else
        podman rm -f "$NAME" >/dev/null 2>&1 || true
        echo "starting Docker Engine container $NAME"
        # label=disable: SELinux hosts let the Engine read the repository unrelabelled.
        podman run -d --name "$NAME" --privileged --security-opt label=disable \
            -v "$NAME-data:/var/lib/docker" -v "$REPO:/src:ro" \
            "$DIND_IMAGE" >/dev/null
    fi
    for _ in $(seq 60); do
        in_engine docker info >/dev/null 2>&1 && break
        sleep 1
    done
    in_engine docker info >/dev/null 2>&1 || { podman logs "$NAME" >&2; die "dockerd did not start"; }
    in_engine docker version
}

load() {
    require_running
    local images=("$@") image
    if [ "${#images[@]}" -eq 0 ]; then
        mapfile -t images < <(compose config --images | sort -u)
    fi
    for image in "${images[@]}"; do
        # A reference pinned by digest (redis) keeps its digest only when pulled: an image
        # loaded from an archive has no repository digest, and compose would pull it anyway.
        if [[ "$image" == *@sha256:* ]]; then
            echo "pulling $image"
            in_engine docker pull -q "$image" >/dev/null || die "pulling $image failed"
            continue
        fi
        podman image exists "$image" || podman pull -q "$image" >/dev/null \
            || die "image $image is neither in podman nor pullable"
        echo "loading $image"
        podman save --format docker-archive "$image" | in_engine docker load -q >/dev/null \
            || die "loading $image failed"
    done
}

up() {
    require_running
    # --wait: returns once every service is running and healthy (db-init: exited 0). Then
    # nginx is restarted, as after every `up -d` that may have recreated one of its upstreams
    # (docker/README.md, "Restart nginx after recreating an upstream").
    compose up -d --wait --wait-timeout 600 --scale certbot=0
    compose restart nginx
    compose up -d --wait --wait-timeout 600 --scale certbot=0
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
    start) start ;;
    load) load "$@" ;;
    up) up ;;
    test)
        require_running
        BBB_SHARED_SECRET="$(sed -n 's/^BBB_SHARED_SECRET=//p' "$HERE/fixture.env")" \
            "$HERE/join-path.sh" --insecure --docker "podman exec -i $NAME docker" \
            --compose "podman exec -i $NAME docker compose --project-directory /src -f /src/docker-compose.yml --env-file /src/docker/tests/stack/fixture.env" \
            --client-image "localhost/bbb-graphql-actions:$TAG" "$@"
        ;;
    compose) require_running; compose "$@" ;;
    docker) require_running; in_engine docker "$@" ;;
    stop)
        podman rm -f "$NAME" >/dev/null 2>&1 || true
        podman volume rm -f "$NAME-data" >/dev/null 2>&1 || true
        echo "removed $NAME and its volume $NAME-data"
        ;;
    -h | --help) usage ;;
    *) echo "unknown command: $cmd" >&2; usage ;;
esac
