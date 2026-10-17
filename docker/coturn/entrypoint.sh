#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=docker/lib/entrypoint-lib.sh
source /usr/local/lib/bbb/entrypoint-lib.sh

BBB_LOG_TAG=coturn
bbb_init "$@"
set -- "${BBB_ARGS[@]}"
# Arguments starting with "-" are extra turnserver options, as with the coturn image.
if [ "$#" -eq 0 ] || [ "${1:0:1}" = "-" ]; then
    set -- turnserver -c /etc/turnserver.conf --pidfile= --log-file=stdout "$@"
fi

# 1. validate
bbb_require BBB_DOMAIN
bbb_require_match BBB_DOMAIN '([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
bbb_require_secret TURN_SECRET
bbb_require_match TURN_SECRET '[A-Za-z0-9+/=]{32,}'
bbb_default TURN_RELAY_PORT_MIN 49160
bbb_default TURN_RELAY_PORT_MAX 49199
bbb_require_match TURN_RELAY_PORT_MIN '[1-9][0-9]{0,4}'
bbb_require_match TURN_RELAY_PORT_MAX '[1-9][0-9]{0,4}'
if [ "$TURN_RELAY_PORT_MAX" -gt 65535 ]; then
    bbb_die "TURN_RELAY_PORT_MAX must be at most 65535"
fi
if [ "$TURN_RELAY_PORT_MIN" -gt "$TURN_RELAY_PORT_MAX" ]; then
    bbb_die "TURN_RELAY_PORT_MIN must not be greater than TURN_RELAY_PORT_MAX"
fi
bbb_default BBB_LIVEKIT_IP 172.30.82.20
bbb_require_match BBB_LIVEKIT_IP '((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'

# 3. render. /etc/turnserver.conf is a link into /run/turnserver, the only writable path;
# render-only mode writes a plain file at the bare-metal path. A file mounted there (engines
# follow the link) is refused: replacing the configuration is not supported.
dest="$(bbb_path /etc/turnserver.conf)"
if ! bbb_is_render_only; then
    if [ "$(readlink -- "$dest" || true)" != /run/turnserver/turnserver.conf ] \
        || awk '$5 == "/etc/turnserver.conf" || $5 == "/run/turnserver/turnserver.conf" { found = 1 } END { exit !found }' /proc/self/mountinfo; then
        bbb_die "a file is mounted at /etc/turnserver.conf; replacing the coturn configuration is not supported"
    fi
    dest=/run/turnserver/turnserver.conf
fi
bbb_render --mode 0600 /usr/local/share/bbb/templates/turnserver.conf "$dest"

# 5. exec
bbb_exec "$@"
