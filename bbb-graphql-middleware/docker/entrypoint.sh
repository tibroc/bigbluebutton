#!/usr/bin/env bash
# Entrypoint of the bbb-graphql-middleware image. Nothing is configured at start: the image's
# /usr/share/bbb-graphql-middleware/config.yml already holds the container wiring (Dockerfile),
# and the binary merges the Tier 3 override /etc/bigbluebutton/bbb-graphql-middleware.yml over
# it itself (config/Config.go), as on bare metal. No configuration contract variable applies.
set -euo pipefail          # never set -x: xtrace prints every value, secrets included
# shellcheck source=docker/lib/entrypoint-lib.sh
source /usr/local/lib/bbb/entrypoint-lib.sh
BBB_LOG_TAG=graphql-middleware

bbb_init "$@"
set -- "${BBB_ARGS[@]}"
[ "$#" -gt 0 ] || set -- bbb-graphql-middleware

# 3. render: --render-only writes the config.yml the binary reads, at its own path
config=/usr/share/bbb-graphql-middleware/config.yml
if bbb_is_render_only; then
    dest="$(bbb_path "$config")"
    mkdir -p "$(dirname "$dest")"
    cp "$config" "$dest"
fi

# 5. exec
bbb_exec "$@"
