#!/usr/bin/env bash
# Build-time configuration of bbb-webhooks: writes config/default.yml from the shipped
# config/default.example.yml the way the package's postinst does
# (build/packages-template/bbb-webhooks/after-install.sh). The postinst edits that depend on a
# deploy-time value (shared secret, server domain) and the Bearer auth switch are environment
# variables instead (node-config custom-environment-variables.yml), exported by the
# entrypoint, so the file is the same for every deployment.
#
# Usage: configure.sh APP_DIR
set -euo pipefail

app="$1"
target="$app/config/default.yml"

cp "$app/config/default.example.yml" "$target"

# --- postinst edits (after-install.sh), in postinst order ---------------------------------
# Not applied:
# - bbb.sharedSecret: the secret is the environment variable SHARED_SECRET; the shipped
#   placeholder is removed below.
# - bbb.serverDomain: environment variable SERVER_DOMAIN (the shipped value stays, unused).
# - bbb.auth2_0 = true: the file keeps the shipped `false`; the entrypoint sets BEARER_AUTH=true
#   when WEBHOOKS_BEARER_AUTH is true (any non-empty BEARER_AUTH enables it, so "false" cannot
#   be passed as a value).
yq e -i '.modules."../out/webhooks/index.js".config.getRaw = false' "$target"
yq e -i '.log.filename = "/var/log/bbb-webhooks/bbb-webhooks.log"' "$target"

# --- container changes ---------------------------------------------------------------------
yq e -i 'del(.bbb.sharedSecret)' "$target"

# --- checks: fail the build if a new upstream version changes what the edits rely on ------
check() {
    local expr="$1" want="$2" got
    got="$(yq e "$expr" "$target")"
    if [ "$got" != "$want" ]; then
        echo "configure.sh: $expr is '$got', expected '$want'" >&2
        exit 1
    fi
}
check '.bbb.auth2_0' false
check '.bbb | has("sharedSecret")' false
# Logs go to stdout only, as shipped.
check '.log.stdout' true
check '.log.file' false
check '.modules."../out/webhooks/index.js".config.api.port' 3005

chmod 0644 "$target"
