#!/usr/bin/env bash
# Entrypoint of the akka-apps image. akka-apps reads its configuration with Typesafe Config
# (HOCON), which takes values from the environment natively: the image's application.conf
# (upstream's, with the container wiring of docker/application.conf.patch) references
# ${BBB_DOMAIN}, ${?BBB_SHARED_SECRET} and ${?POSTGRES_BBB_CORE_PASSWORD}. So this script only
# validates them and chooses the configuration file; nothing with a secret is written.
#
# Configuration file (-Dconfig.file), as on bare metal:
#   /etc/bigbluebutton/bbb-apps-akka.conf               if mounted (Tier 3; it starts with
#       include "/usr/share/bbb-apps-akka/conf/application.conf", then later keys win)
#   /usr/share/bbb-apps-akka/conf/application.conf      otherwise
#
# --render-only DIR writes no configuration (there is nothing to render); it copies the image's
# application.conf to DIR at its bare-metal path, so that the golden and parity tests cover it.
set -euo pipefail          # never set -x: xtrace prints every value, secrets included
# shellcheck source=docker/lib/entrypoint-lib.sh
source /usr/local/lib/bbb/entrypoint-lib.sh
BBB_LOG_TAG=akka-apps

APP_HOME=/usr/share/bbb-apps-akka
APP_CONF="$APP_HOME/conf/application.conf"
OVERRIDE=/etc/bigbluebutton/bbb-apps-akka.conf

bbb_init "$@"
set -- "${BBB_ARGS[@]}"

# 1. validate. The patterns are the contract's; they also reject upstream's defaults
# (sharedSecret "changeme", the bbb_core role password "bbb_core").
bbb_require_match BBB_DOMAIN '([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
bbb_require_match BBB_SHARED_SECRET '[A-Za-z0-9]{32,}'
bbb_require_secret BBB_SHARED_SECRET
# Optional in the contract, but without it HOCON would keep upstream's fixed password.
bbb_require_match POSTGRES_BBB_CORE_PASSWORD '[A-Za-z0-9]{32,}'
# 2. derive: nothing; HOCON reads the three variables from the environment.
export BBB_DOMAIN BBB_SHARED_SECRET POSTGRES_BBB_CORE_PASSWORD

# 3. render: nothing; see the header.
if bbb_is_render_only; then
    dest="$(bbb_path "$APP_CONF")"
    mkdir -p "$(dirname "$dest")"
    cp "$APP_CONF" "$dest"
fi

# 4. merge: the Tier 3 file replaces application.conf as the file the JVM loads.
config_file="$APP_CONF"
if [ -e "$OVERRIDE" ] || [ -L "$OVERRIDE" ]; then
    [ -f "$OVERRIDE" ] || bbb_die "$OVERRIDE is not a regular file"
    [ -r "$OVERRIDE" ] || bbb_die "$OVERRIDE is not readable"
    config_file="$OVERRIDE"
    bbb_log "using $OVERRIDE"
fi

# Default command: upstream's start script (build.sbt: JavaServerAppPackaging), started from
# its directory like the systemd unit (WorkingDirectory), as logback.xml is a relative path.
# A -Dconfig.file argument comes after the packaged one (conf/application.ini), so it wins.
[ "$#" -gt 0 ] || set -- "$APP_HOME/bin/bbb-apps-akka" "-Dconfig.file=$config_file"
cd "$APP_HOME"

# 5. exec
bbb_exec "$@"
