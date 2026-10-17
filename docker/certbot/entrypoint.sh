#!/usr/bin/env bash
# certbot entrypoint: the certificate service of the TLS edge (ADR-07). Renders certbot's
# configuration from BBB_DOMAIN and ACME_EMAIL and execs the obtain/renew loop. No network
# access before bbb_exec, so render-only mode never contacts an ACME server.
set -euo pipefail
# shellcheck source=docker/lib/entrypoint-lib.sh
source /usr/local/lib/bbb/entrypoint-lib.sh
BBB_LOG_TAG=certbot

bbb_init "$@"
set -- "${BBB_ARGS[@]}"
[ "$#" -gt 0 ] || set -- bbb-certbot-loop

# 1. validate (patterns from docker/config-contract.yaml)
bbb_require_match BBB_DOMAIN '([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
bbb_require_match ACME_EMAIL '[A-Za-z0-9._%+-]+@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}'
# The address from bbb-install's documentation, refused as bbb-install does.
if [ "${ACME_EMAIL,,}" = info@example.com ]; then
    bbb_die "ACME_EMAIL is the example address from the documentation; set your own contact address"
fi

# 3. render
dest="$(bbb_path /etc/bbb-certbot/cli.ini)"
bbb_render /usr/local/share/bbb/certbot/cli.ini "$dest"

# 5. exec
bbb_exec "$@"
