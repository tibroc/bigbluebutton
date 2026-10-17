#!/usr/bin/env bash
# The db-init job (ADR-14), installed as /usr/local/bin/bbb-db-init and started by
# /entrypoint.sh after it validated the environment.
#
# 1. Waits for the postgres service (PGHOST, PGPORT) and connects as the superuser with
#    POSTGRES_PASSWORD.
# 2. (Re)creates bbb_graphql, hasura_app and blocknote_app (recreate.sql) when the version
#    recorded in the table public.bbb_db_init of the postgres database differs from this
#    image's version, or one of the three databases is missing. Otherwise they are kept: a
#    plain restart changes nothing.
# 3. Sets the role passwords (passwords.sql) after a recreate, or when a role cannot log in
#    with its contract password (e.g. the password was changed in .env).
#
# The image version is written at build time to /usr/share/bbb-db-init/version: the image's
# release version (DOCKER_META_VERSION from docker/metadata-action, `local` without it) and a
# checksum of the SQL the job runs, so a changed schema always counts as a new version.
set -euo pipefail          # never set -x: xtrace prints every value, secrets included
# shellcheck source=docker/lib/entrypoint-lib.sh
source /usr/local/lib/bbb/entrypoint-lib.sh
BBB_LOG_TAG=db-init

SQL_DIR=/usr/share/bbb-db-init
WAIT_SECONDS=60
DATABASES="'bbb_graphql', 'hasura_app', 'blocknote_app'"

version="$(cat "$SQL_DIR/version")"
[ -n "$version" ] || bbb_die "empty image version in $SQL_DIR/version"

# psql as the superuser; the password reaches psql through its environment only.
psql_su() {
    PGPASSWORD="$POSTGRES_PASSWORD" psql -X -w -q -v ON_ERROR_STOP=1 -U postgres "$@"
}

# can_login ROLE DATABASE PASSWORD-VARIABLE
can_login() {
    PGPASSWORD="${!3}" psql -X -w -q -U "$1" -d "$2" -At -c 'SELECT 1' >/dev/null 2>&1
}

bbb_log "waiting for postgres at ${PGHOST:-local socket}:${PGPORT:-5432}"
for ((i = 0; i < WAIT_SECONDS; i++)); do
    pg_isready -q && break
    sleep 1
done
pg_isready -q || bbb_die "postgres not ready after ${WAIT_SECONDS}s"
psql_su -d postgres -At -c 'SELECT 1' >/dev/null

applied=""
if [ "$(psql_su -d postgres -At -c "SELECT to_regclass('public.bbb_db_init') IS NOT NULL")" = t ]; then
    applied="$(psql_su -d postgres -At -c 'SELECT version FROM public.bbb_db_init')"
fi
present="$(psql_su -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname IN ($DATABASES)")"

recreated=0
if [ "$applied" = "$version" ] && [ "$present" = 3 ]; then
    bbb_log "databases were created by this image version; kept"
else
    bbb_log "image version changed or a database is missing; recreating bbb_graphql, hasura_app, blocknote_app"
    psql_su -d postgres -v bbb_version="$version" -f "$SQL_DIR/recreate.sql"
    recreated=1
fi

if [ "$recreated" = 1 ] \
    || ! can_login hasura_app hasura_app POSTGRES_HASURA_APP_PASSWORD \
    || ! can_login bbb_core bbb_graphql POSTGRES_BBB_CORE_PASSWORD \
    || ! can_login bbb_hasura bbb_graphql POSTGRES_BBB_HASURA_PASSWORD \
    || ! can_login blocknote_app blocknote_app POSTGRES_BLOCKNOTE_PASSWORD; then
    bbb_log "setting role passwords"
    psql_su -d postgres -f "$SQL_DIR/passwords.sql"
else
    bbb_log "role passwords unchanged"
fi
bbb_log "done"
