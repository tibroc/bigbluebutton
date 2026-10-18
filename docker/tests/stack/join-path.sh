#!/usr/bin/env bash
# Join-path test for a running stack: what a browser does when a user joins, up to the GraphQL
# subscription, before and after `docker compose restart`.
#
# Usage: BBB_SHARED_SECRET=... docker/tests/stack/join-path.sh [OPTION...]
#   --domain NAME        BBB_DOMAIN of the stack (default bbb.example.com)
#   --connect-ip IP      connect to IP for NAME instead of resolving it (default 127.0.0.1;
#                        empty: use DNS)
#   --insecure           do not verify the server certificate (self-signed stacks)
#   --docker CMD         docker CLI to use (default `docker`)
#   --compose CMD        docker compose command of the stack (default `docker compose`, run in
#                        the directory of docker-compose.yml)
#   --client-image IMG   image with Node 24 for the client part (default
#                        localhost/bbb-graphql-actions:4.0.1)
#   --no-restart         skip the restart cycles
#   --keep-going         go on with the restart cycles after failed client steps
#   --wait SECONDS       how long the services may take to become healthy (default 300; the
#                        longest start_period in docker-compose.yml is 200 s)
#   --timeout SECONDS    per-request timeout of the client (default 30)
#
# JOIN_PATH_DEBUG=1 prints the GraphQL WebSocket messages the client receives (stderr).
#
# Steps: stack-healthy, then the client steps of join-path-client.mjs (api-index, create, join,
# html5client, meetingStaticData, graphql-ws, livekit); then restart (`docker compose restart`),
# stack-healthy-after-restart, nginx restarted as docker/README.md requires, and the client
# steps again; then restart-redis-late (every other service restarted while redis is stopped,
# redis started 20 s later), stack-healthy-after-redis-late, nginx restarted, and the client
# steps again. Prints `STEP <name>: OK|FAIL ...`,
# then `JOIN-PATH PASS` or `JOIN-PATH FAIL`. Exit 0 PASS, 1 FAIL, 2 usage error.
#
# The client runs in a container on the host network of the Docker Engine, where the stack
# publishes 443 (with dind.sh: inside the Engine container). The shared secret goes to it on
# stdin, never as an argument or in the environment; session tokens and checksums are redacted
# from the output.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0" >&2; exit 2; }

domain=bbb.example.com
connect_ip=127.0.0.1
insecure=0
docker_cmd=docker
compose_cmd="docker compose"
client_image=localhost/bbb-graphql-actions:4.0.1
restart=1
keep_going=0
failed=0
wait_s=300
redis_late_s=20
timeout_s=30
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) [ $# -ge 2 ] || usage; domain="$2"; shift 2 ;;
        --connect-ip) [ $# -ge 2 ] || usage; connect_ip="$2"; shift 2 ;;
        --insecure) insecure=1; shift ;;
        --docker) [ $# -ge 2 ] || usage; docker_cmd="$2"; shift 2 ;;
        --compose) [ $# -ge 2 ] || usage; compose_cmd="$2"; shift 2 ;;
        --client-image) [ $# -ge 2 ] || usage; client_image="$2"; shift 2 ;;
        --no-restart) restart=0; shift ;;
        --keep-going) keep_going=1; shift ;;
        --wait) [ $# -ge 2 ] || usage; wait_s="$2"; shift 2 ;;
        --timeout) [ $# -ge 2 ] || usage; timeout_s="$2"; shift 2 ;;
        -h | --help) usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done
[[ "$wait_s" =~ ^[0-9]+$ && "$timeout_s" =~ ^[0-9]+$ ]] || usage
[ -n "${BBB_SHARED_SECRET:-}" ] || { echo "join-path.sh: BBB_SHARED_SECRET is not set" >&2; exit 2; }
secret="$BBB_SHARED_SECRET"
unset BBB_SHARED_SECRET

read -r -a DOCKER <<<"$docker_cmd"
read -r -a COMPOSE <<<"$compose_cmd"

# health: one line per service, "service|state|health|exitcode" (health empty without healthcheck).
health() { "${COMPOSE[@]}" ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}'; }

# wait_healthy STEP: every service running and healthy (a service without healthcheck: running),
# run-only jobs (db-init) exited 0, within $wait_s seconds.
wait_healthy() {
    local step="$1" start=$SECONDS pending lines
    while :; do
        lines="$(health)" || lines=""
        pending="$(awk -F'|' '
            $2 == "exited" && $4 == 0 && $1 == "db-init" { next }
            $2 == "running" && ($3 == "healthy" || $3 == "") { next }
            { printf "%s%s:%s/%s", sep, $1, $2, ($3 == "" ? "-" : $3); sep = " " }
            END { if (NR == 0) printf "no services" }' <<<"$lines")"
        if [ -z "$pending" ]; then
            echo "STEP $step: OK all services healthy after $((SECONDS - start))s"
            return 0
        fi
        if [ $((SECONDS - start)) -ge "$wait_s" ]; then
            echo "STEP $step: FAIL not healthy after ${wait_s}s: $pending"
            return 1
        fi
        sleep 5
    done
}

client() {
    local args=(run --rm -i --network host)
    [ -z "$connect_ip" ] || args+=(--add-host "$domain:$connect_ip")
    [ "$insecure" -eq 0 ] || args+=(-e NODE_TLS_REJECT_UNAUTHORIZED=0 -e NODE_NO_WARNINGS=1)
    [ -z "${JOIN_PATH_DEBUG:-}" ] || args+=(-e JOIN_PATH_DEBUG=1)
    args+=(--entrypoint node "$client_image" --input-type=module -e "$(cat "$HERE/join-path-client.mjs")"
        -- "https://$domain" "$timeout_s")
    printf '%s\n' "$secret" | "${DOCKER[@]}" "${args[@]}"
}

result() {
    echo "JOIN-PATH $1"
    [ "$1" = PASS ]
}

# restart_nginx SUFFIX: nginx resolves its upstreams once, at start, and restarted containers
# come back with other addresses, so nginx is restarted once the others are healthy
# (docker/README.md, "Restart nginx ..."; RB-04 runbook step 14).
restart_nginx() {
    if "${COMPOSE[@]}" restart nginx >/dev/null 2>&1; then
        echo "STEP nginx-restart-$1: OK docker compose restart nginx"
    else
        echo "STEP nginx-restart-$1: FAIL docker compose restart nginx exited non-zero"
        result FAIL; exit 1
    fi
    wait_healthy "stack-healthy-$1-nginx" || { result FAIL; exit 1; }
}

# client_steps: the client steps; with --keep-going a failure is remembered, not fatal.
client_steps() {
    client && return 0
    failed=1
    [ "$keep_going" -eq 1 ] || { result FAIL; exit 1; }
}

wait_healthy stack-healthy || { result FAIL; exit 1; }
client_steps
if [ "$restart" -eq 1 ]; then
    if "${COMPOSE[@]}" restart >/dev/null 2>&1; then
        echo "STEP restart: OK docker compose restart"
    else
        echo "STEP restart: FAIL docker compose restart exited non-zero"
        result FAIL; exit 1
    fi
    wait_healthy stack-healthy-after-restart || { health | sed 's/^/  /; s/|/ /g'; result FAIL; exit 1; }
    restart_nginx after-restart
    client_steps

    # `docker compose restart` restarts every service at once, in no particular order, so a
    # service may start before redis is back. Make that deterministic: restart all other
    # services while redis is stopped, then start redis.
    mapfile -t others < <("${COMPOSE[@]}" config --services | grep -vx redis)
    if "${COMPOSE[@]}" stop redis >/dev/null 2>&1 \
        && "${COMPOSE[@]}" restart "${others[@]}" >/dev/null 2>&1 \
        && sleep "$redis_late_s" \
        && "${COMPOSE[@]}" start redis >/dev/null 2>&1; then
        echo "STEP restart-redis-late: OK restarted the others with redis stopped, redis started ${redis_late_s}s later"
    else
        echo "STEP restart-redis-late: FAIL a docker compose stop/restart/start exited non-zero"
        result FAIL; exit 1
    fi
    wait_healthy stack-healthy-after-redis-late || { health | sed 's/^/  /; s/|/ /g'; result FAIL; exit 1; }
    restart_nginx after-redis-late
    client_steps
fi
[ "$failed" -eq 0 ] || { result FAIL; exit 1; }
result PASS
