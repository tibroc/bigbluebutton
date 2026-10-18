#!/usr/bin/env bash
# Entrypoint of the bbb-webhooks image. bbb-webhooks reads its configuration with node-config
# from the directories it sets itself (src/common/env.js): the Tier 3 override
# /etc/bigbluebutton/bbb-webhooks/production.yml if mounted (NODE_ENV=production, as the
# bare-metal unit sets it), the image's config/default.yml (written at build time by
# configure.sh), then environment variables, which win over both files.
# This entrypoint only validates and exports those variables; it renders nothing.
set -euo pipefail          # never set -x: xtrace prints every value, secrets included
# shellcheck source=docker/lib/entrypoint-lib.sh
source /usr/local/lib/bbb/entrypoint-lib.sh
BBB_LOG_TAG=bbb-webhooks

bbb_init "$@"
set -- "${BBB_ARGS[@]}"
[ "$#" -gt 0 ] || set -- node app.js

# 1. validate (patterns from docker/config-contract.yaml). The patterns also reject the
# placeholders shipped in default.example.yml, which upstream accepts.
bbb_require_match BBB_DOMAIN '([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
# Format first: its message never contains the value. The placeholder message of
# bbb_require_secret contains the word "secret", which is itself a placeholder value.
bbb_require_match BBB_SHARED_SECRET '[A-Za-z0-9]{32,}'
BBB_SECRET_PLACEHOLDERS+=(mysharedsecret)
bbb_require_secret BBB_SHARED_SECRET
bbb_default WEBHOOKS_BEARER_AUTH true
bbb_require_match WEBHOOKS_BEARER_AUTH 'true|false'
# Container wiring, set in the image.
bbb_require NODE_ENV SERVER_BIND_IP REDIS_HOST

# 2. derive (contract: webhooks_env), node-config environment variables
export SERVER_DOMAIN="$BBB_DOMAIN"
export SHARED_SECRET="$BBB_SHARED_SECRET"
unset BBB_SHARED_SECRET
# bbb-webhooks treats any non-empty BEARER_AUTH, "false" included, as on (LX-2): set it only to
# enable Bearer auth; otherwise bbb.auth2_0 of the files decides (false in default.yml).
if [ "$WEBHOOKS_BEARER_AUTH" = true ]; then
    export BEARER_AUTH=true
else
    unset BEARER_AUTH
fi

# 3. render: nothing at start. In render-only mode, write out the base config the service
# reads, for the golden-file tests.
if bbb_is_render_only; then
    base=/usr/local/bigbluebutton/bbb-webhooks/config/default.yml
    dest="$(bbb_path "$base")"
    mkdir -p "$(dirname "$dest")"
    cp "$base" "$dest"
fi

# 4. merge: node-config merges the Tier 3 override itself.

# 5. exec
bbb_exec "$@"
