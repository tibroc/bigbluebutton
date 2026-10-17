#!/usr/bin/env bash
# Build-time configuration of bbb-webrtc-sfu: writes config/default.yml from the shipped
# config/default.example.yml the way the package's postinst does
# (build/packages-template/bbb-webrtc-sfu/after-install.sh), plus the changes a LiveKit-only
# container needs. None of these settings depends on a deploy-time value, so they are made
# once, in the image. Credentials, the BBB domain and the container wiring are environment
# variables (node-config custom-environment-variables.yml), set by the image and entrypoint.
#
# Usage: configure.sh APP_DIR
set -euo pipefail

app="$1"
target="$app/config/default.yml"

cp "$app/config/default.example.yml" "$target"

# --- postinst edits (after-install.sh), in postinst order ---------------------------------
# Not applied: mediasoup announcedIp and freeswitch.ip/sip_ip (the host IP). Media goes
# through LiveKit, and the FreeSWITCH adapter is removed below (ADR-15).
yq e -i '.mediasoup.workerBalancing.strategy = "least-loaded"' "$target"
yq e -i '.mediasoup.enableWorkerTransposing = true' "$target"
yq e -i '.mediasoup.dedicatedMediaTypeWorkers.audio = "auto"' "$target"
yq e -i '.recordWebcams = true' "$target"
yq e -i '.recordingAdapter = "bbb-webrtc-recorder"' "$target"
yq e -i '.kurento = []' "$target"
yq e -i '.mcs-address = "127.0.0.1"' "$target"
yq e -i '.livekit.enabled = true' "$target"

# --- container changes ---------------------------------------------------------------------
# The postinst writes the LiveKit key pair into this file; here it comes from the environment
# (LIVEKIT_KEY/LIVEKIT_SECRET), so the shipped placeholders are removed.
yq e -i 'del(.livekit.key, .livekit.secret)' "$target"
# No FreeSWITCH in a LiveKit-only stack: without its adapter the SFU makes no ESL connection
# attempts (LX-4).
yq e -i 'del(.["media-server-adapters"][] | select(.name == "Freeswitch"))' "$target"
# Logs go to stdout only.
yq e -i '.log.file = false' "$target"

# --- checks: fail the build if a new upstream version changes what the edits rely on ------
check() {
    local expr="$1" want="$2" got
    got="$(yq e "$expr" "$target")"
    if [ "$got" != "$want" ]; then
        echo "configure.sh: $expr is '$got', expected '$want'" >&2
        exit 1
    fi
}
# The audio adapter is selected by audioMediaServer (lib/audio/audio-req-hdlr.js); it must
# name an adapter that is still configured.
check '.audioMediaServer' mediasoup
check '[.["media-server-adapters"][].name] | join(",")' Kurento,mediasoup
check '.livekit.webhook.port' 3040
check '.livekit.webhook.path' /livekit-webhook
check '.livekit.recordingAdapter' bbb-webrtc-recorder
check '.livekit | has("key") or has("secret")' false

chmod 0644 "$target"
