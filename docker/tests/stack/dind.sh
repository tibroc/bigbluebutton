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
#   up                 issue the test certificate (see below), docker compose up -d --wait,
#                      certbot scaled to 0, then restart nginx
#   test [ARG...]      docker/tests/stack/join-path.sh against the stack (ARGs passed on)
#   webhooks ARG...    docker/tests/stack/webhooks-check.sh against the stack (ARGs passed on)
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
# images from `localhost`, certbot scaled to 0, so no ACME request is ever made. In its place,
# `up` issues a certificate for BBB_DOMAIN from a throwaway test CA (created in the Engine, its
# key discarded after signing) and writes it into the `certs` volume as certbot would;
# docker/tests/stack/compose.test.yml makes bbb-web's JVM trust that CA, as a deployment's JVM
# trusts the public CA of its certificate. Ports are published inside the Engine container's
# network namespace only; nothing is published on the host.
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

COMPOSE_ARGS="--project-directory /src -f /src/docker-compose.yml -f /src/docker/tests/stack/compose.test.yml --env-file /src/docker/tests/stack/fixture.env"

compose() {
    # shellcheck disable=SC2086 # COMPOSE_ARGS is a fixed list of words without spaces
    in_engine docker compose $COMPOSE_ARGS "$@"
}

# Volumes of the test certificate (Engine-local; removed with the Engine by `stop`).
PKI_VOLUME=bbb-test-pki
TRUSTSTORE_VOLUME=bbb-test-truststore

# test_pki: a test CA and a certificate for BBB_DOMAIN signed by it (kept in PKI_VOLUME: the CA
# certificate and the haproxy bundle, certificate and key, as bbb-certbot-deploy-hook writes it);
# a copy of bbb-web's Java truststore with the CA added (TRUSTSTORE_VOLUME). Idempotent.
test_pki() {
    local domain
    domain="$(sed -n 's/^BBB_DOMAIN=//p' "$HERE/fixture.env")"
    [ -n "$domain" ] || die "BBB_DOMAIN is not set in fixture.env"
    in_engine docker volume create "$PKI_VOLUME" >/dev/null
    in_engine docker volume create "$TRUSTSTORE_VOLUME" >/dev/null
    # shellcheck disable=SC2016 # expanded by the shell in the container
    in_engine docker run --rm --user 0 --entrypoint sh -v "$PKI_VOLUME:/pki" "localhost/bbb-haproxy:$TAG" -ec '
        cd /pki
        [ -s certbundle.pem ] && [ -s ca.pem ] && exit 0
        umask 077
        openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -nodes -subj "/CN=BBB stack test CA" \
            -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -keyout ca.key -out ca.pem 2>/dev/null
        openssl req -newkey rsa:2048 -nodes -subj "/CN=$1" -keyout server.key -out server.csr 2>/dev/null
        printf "subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n" "$1" >ext.cnf
        openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -sha256 \
            -extfile ext.cnf -out server.pem 2>/dev/null
        { cat server.pem; echo; cat server.key; } >certbundle.pem
        rm -f ca.key ca.srl server.csr server.key server.pem ext.cnf
        chmod 0644 ca.pem
        echo "issued a test certificate for $1"
    ' sh "$domain"
    # shellcheck disable=SC2016 # expanded by the shell in the container
    in_engine docker run --rm --user 0 --entrypoint bash -v "$PKI_VOLUME:/pki:ro" -v "$TRUSTSTORE_VOLUME:/out" \
        "localhost/bbb-web:$TAG" -ec '
        [ -s /out/cacerts ] && keytool -list -keystore /out/cacerts -storepass changeit -alias bbb-stack-test-ca >/dev/null 2>&1 && exit 0
        cp /etc/ssl/certs/java/cacerts /out/cacerts.tmp
        keytool -importcert -noprompt -alias bbb-stack-test-ca -file /pki/ca.pem -keystore /out/cacerts.tmp -storepass changeit >/dev/null
        chmod 0644 /out/cacerts.tmp
        mv -f /out/cacerts.tmp /out/cacerts
        echo "added the test CA to a copy of the Java truststore"
    '
}

# install_certificate: the bundle into the stack's `certs` volume (created by `up --no-start`),
# with the mode and owner bbb-certbot-deploy-hook gives it (haproxy's UID/GID 99).
install_certificate() {
    in_engine docker run --rm --user 0 --entrypoint sh -v "$PKI_VOLUME:/pki:ro" -v bigbluebutton_certs:/certs \
        "localhost/bbb-haproxy:$TAG" -ec 'install -o 99 -g 99 -m 0640 /pki/certbundle.pem /certs/certbundle.pem'
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
    test_pki
    compose up --no-start --scale certbot=0
    install_certificate
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
            --compose "podman exec -i $NAME docker compose $COMPOSE_ARGS" \
            --client-image "localhost/bbb-graphql-actions:$TAG" "$@"
        ;;
    webhooks)
        require_running
        BBB_SHARED_SECRET="$(sed -n 's/^BBB_SHARED_SECRET=//p' "$HERE/fixture.env")" \
            "$HERE/webhooks-check.sh" "$@" --docker "podman exec -i $NAME docker" \
            --image "localhost/bbb-webhooks:$TAG"
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
