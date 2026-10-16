#!/usr/bin/env bash
# Additional tests for docker/lib/entrypoint-lib.sh: behaviour the interface tests
# (test-entrypoint-lib.sh) do not pin down. Same harness and conventions.
#
# Usage: docker/tests/lib/test-entrypoint-lib-extra.sh
#   BBB_ENTRYPOINT_LIB=/path/to/entrypoint-lib.sh overrides the helper location.

# Snippets passed to run_lib are single-quoted on purpose: they are expanded by the child shell.
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${BBB_ENTRYPOINT_LIB:-$HERE/../../lib/entrypoint-lib.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "ok   $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL $1${2:+: $2}"; }

run_lib() {
    local snippet="$1"
    set +e
    env -i PATH="$PATH" HOME="$WORK" TMPDIR="$WORK" "${@:2}" \
        bash -c "set -euo pipefail; source '$LIB'; $snippet" \
        >"$WORK/out" 2>"$WORK/err"
    RC=$?
    set -e
    OUT="$(cat "$WORK/out")"
    ERR="$(cat "$WORK/err")"
}

expect_rc() { if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1" "exit $RC, expected $2; stderr: $ERR"; fi; }
expect_out() { if [ "$OUT" = "$2" ]; then pass "$1"; else fail "$1" "got '$OUT'"; fi; }
expect_err_contains() { case "$ERR" in *"$2"*) pass "$1" ;; *) fail "$1" "stderr does not contain '$2': $ERR" ;; esac; }
expect_not_contains() { case "$2" in *"$3"*) fail "$1" "output contains '$3'" ;; *) pass "$1" ;; esac; }
expect_file() { # name file expected-content
    if [ -f "$2" ] && [ "$(cat "$2"; printf x)" = "$3"x ]; then pass "$1"
    else fail "$1" "$(cat "$2" 2>&1)"; fi
}

[ -r "$LIB" ] || { echo "helper not found: $LIB"; exit 1; }
T="$WORK/tpl"
mkdir -p "$T"

# --- bbb_render: what passes through ----------------------------------------------------

printf '%s\n' 'a=${BBB_DOMAIN}' 'b=$host ${host} ${lower_case}' 'c=${?INTERFACE} ${BBB_DOMAIN:-x}' 'd=$$ \$' >"$T/pass.tmpl"
run_lib "bbb_render '$T/pass.tmpl' '$WORK/r/pass.out'" BBB_DOMAIN=bbb.example.com host=WRONG lower_case=WRONG INTERFACE=WRONG
expect_rc "render: renders template with non-project variables" 0
expect_file "render: only braced upper-case names are substituted" "$WORK/r/pass.out" \
    "$(printf '%s\n' 'a=bbb.example.com' 'b=$host ${host} ${lower_case}' 'c=${?INTERFACE} ${BBB_DOMAIN:-x}' 'd=$$ \$')
"

printf 'x=${BBB_DERIVED}\n' >"$T/derived.tmpl"
run_lib "BBB_DERIVED=https://bbb.example.com; bbb_render '$T/derived.tmpl' '$WORK/r/derived.out'; printf %s \"\$(bash -c 'printf %s \"\${BBB_DERIVED:-unset}\"')\""
expect_rc "render: unexported shell variable is substituted" 0
expect_file "render: derived value written" "$WORK/r/derived.out" "x=https://bbb.example.com
"
expect_out "render: caller environment unchanged (not exported)" "unset"

run_lib "bbb_render '$T/derived.tmpl' '$WORK/r/empty.out'" BBB_DERIVED=
expect_rc "render: set but empty variable is allowed" 0
expect_file "render: empty value substituted" "$WORK/r/empty.out" "x=
"

printf 'v=${BBB_VALUE}\n' >"$T/special.tmpl"
run_lib "bbb_render '$T/special.tmpl' '$WORK/r/special.out'" 'BBB_VALUE=a$b\c&d/e"f'"'g"
expect_file "render: special characters in values copied literally" "$WORK/r/special.out" 'v=a$b\c&d/e"f'"'g
"

printf 'static\n\n' >"$T/static.tmpl"
run_lib "bbb_render '$T/static.tmpl' '$WORK/r/static.out'"
expect_rc "render: template without variables" 0
if cmp -s "$T/static.tmpl" "$WORK/r/static.out"; then pass "render: template without variables copied byte for byte"
else fail "render: template without variables copied byte for byte"; fi

printf 'a=${BBB_DOMAIN}\nb=$BBB_DOMAIN\n' >"$T/unbraced.tmpl"
run_lib "bbb_render '$T/unbraced.tmpl' '$WORK/r/unbraced.out'" BBB_DOMAIN=bbb.example.com
expect_rc "render: unbraced form of a project variable fails" 1
expect_err_contains "render: names the unbraced variable" "BBB_DOMAIN"

printf 'a=${BBB_A}\nb=${BBB_B}\n' >"$T/two.tmpl"
run_lib "bbb_render '$T/two.tmpl' '$WORK/r/two.out'"
expect_err_contains "render: reports every undefined variable (first)" "BBB_A"
expect_err_contains "render: reports every undefined variable (second)" "BBB_B"

# --- bbb_render: failure leaves no partial files -----------------------------------------

printf 'old\n' >"$WORK/r/keep.out"
printf 'missing=${BBB_NOT_SET}\n' >"$T/missing.tmpl"
run_lib "bbb_render '$T/missing.tmpl' '$WORK/r/keep.out'"
expect_rc "render: failure exits 1" 1
expect_file "render: failure keeps the existing destination" "$WORK/r/keep.out" "old
"
if compgen -G "$WORK/r/*.tmp.*" >/dev/null; then fail "render: no temporary files left"; else pass "render: no temporary files left"; fi

run_lib "bbb_render '$T/does-not-exist.tmpl' '$WORK/r/x.out'"
expect_rc "render: missing template fails" 1
expect_err_contains "render: names the missing template" "does-not-exist.tmpl"

run_lib "umask 077; bbb_render '$T/derived.tmpl' '$WORK/r/mode.out'" BBB_DERIVED=fixtureturnsecretnotreal000000000000000000000000
if [ "$(stat -c %a "$WORK/r/mode.out")" = 600 ]; then pass "render: umask 077 gives 0600"
else fail "render: umask 077 gives 0600" "$(stat -c %a "$WORK/r/mode.out")"; fi

# --- bbb_require_secret ------------------------------------------------------------------

run_lib 'bbb_require_secret TURN_SECRET' TURN_SECRET=CHANGEME
expect_rc "secret: placeholders compared case-insensitively" 1
run_lib 'BBB_SECRET_PLACEHOLDERS+=(bbb_core); bbb_require_secret POSTGRES_BBB_CORE_PASSWORD' POSTGRES_BBB_CORE_PASSWORD=bbb_core
expect_rc "secret: entrypoints can add placeholders" 1
expect_not_contains "secret: added placeholder not echoed" "$OUT$ERR" "bbb_core"

run_lib 'bbb_require "bad-name"'
expect_rc "require: invalid variable name fails" 1

# --- bbb_feature_enabled -----------------------------------------------------------------

run_lib 'bbb_feature_enabled greenlight' 'BBB_FEATURES=recording, greenlight'
expect_rc "feature: spaces in the list are tolerated" 0
run_lib 'if bbb_feature_enabled webhooks; then echo on; else echo off; fi' BBB_FEATURES=recording
expect_out "feature: usable in if under set -e" "off"

# --- bbb_init / bbb_path / bbb_is_render_only --------------------------------------------

run_lib "bbb_init --render-only '$WORK/r3/' nginx -g 'daemon off;'; bbb_path /etc/x; printf '%s|' \"\${BBB_ARGS[@]}\"; bbb_is_render_only && echo yes"
expect_out "init: trailing slash stripped, remaining args kept" "$WORK/r3/etc/x
nginx|-g|daemon off;|yes"

run_lib 'bbb_init nginx -g "daemon off;"; printf "%s|" "${BBB_ARGS[@]}"; bbb_is_render_only || echo no'
expect_out "init: normal mode keeps all args" "nginx|-g|daemon off;|no"

run_lib 'bbb_init; printf "%s" "${#BBB_ARGS[@]}"'
expect_out "init: no args gives empty BBB_ARGS under set -u" "0"

run_lib 'bbb_path etc/relative'
expect_rc "path: relative path fails" 1

run_lib "bbb_init --render-only '$WORK/r4'; bbb_render '$T/static.tmpl' \"\$(bbb_path /etc/bigbluebutton/static.conf)\""
if [ -f "$WORK/r4/etc/bigbluebutton/static.conf" ]; then pass "render-only: bbb_render into bbb_path lands below the dir"
else fail "render-only: bbb_render into bbb_path lands below the dir"; fi

run_lib 'bbb_exec'
expect_rc "exec: no command fails" 1

# --- bbb_merge_yaml ----------------------------------------------------------------------

Y="$WORK/yaml"
mkdir -p "$Y"
printf 'a:\n  b: 1\n  c: [1, 2]\nd: x\n' >"$Y/base.yml"
printf -- '- 1\n- 2\n' >"$Y/list.yml"
printf 'a: {b: 2}\n---\na: {b: 3}\n' >"$Y/multi.yml"
: >"$Y/empty.yml"
printf '# only a comment\n' >"$Y/comment.yml"

run_lib "bbb_merge_yaml '$Y/base.yml' '$Y/list.yml' '$WORK/m/list.yml'"
expect_rc "merge: override that is not a mapping fails" 1
expect_err_contains "merge: names the non-mapping override" "list.yml"

run_lib "bbb_merge_yaml '$Y/base.yml' '$Y/multi.yml' '$WORK/m/multi.yml'"
expect_rc "merge: multi-document override fails" 1

for f in empty comment; do
    run_lib "bbb_merge_yaml '$Y/base.yml' '$Y/$f.yml' '$WORK/m/$f.yml'"
    expect_rc "merge: $f override is fine" 0
    if [ "$(yq -o=json -I=0 '.' "$WORK/m/$f.yml" 2>/dev/null)" = "$(yq -o=json -I=0 '.' "$Y/base.yml")" ]; then
        pass "merge: $f override keeps base"
    else fail "merge: $f override keeps base" "$(cat "$WORK/m/$f.yml" 2>&1)"; fi
done

printf 'old: true\n' >"$WORK/m/keep.yml"
printf 'a: [unclosed\n' >"$Y/broken.yml"
run_lib "bbb_merge_yaml '$Y/base.yml' '$Y/broken.yml' '$WORK/m/keep.yml'"
expect_file "merge: failure keeps the existing destination" "$WORK/m/keep.yml" "old: true
"

# The override is valid, the base is not: yq itself fails while writing the destination.
printf 'a: [unclosed\n' >"$Y/broken-base.yml"
printf 'a: 1\n' >"$Y/ok.yml"
run_lib "bbb_merge_yaml '$Y/broken-base.yml' '$Y/ok.yml' '$WORK/m/keep.yml'"
expect_rc "merge: failing yq exits 1" 1
expect_file "merge: failing yq keeps the existing destination" "$WORK/m/keep.yml" "old: true
"
if compgen -G "$WORK/m/*.tmp.*" >/dev/null; then fail "merge: no temporary files left"; else pass "merge: no temporary files left"; fi

run_lib "bbb_merge_yaml '$Y/no-base.yml' '$Y/empty.yml' '$WORK/m/x.yml'"
expect_rc "merge: missing base fails" 1
expect_err_contains "merge: names the missing base" "no-base.yml"

printf 'secret: fixturelivekitapisecretnotreal000000000000000000\n' >"$Y/secret.yml"
run_lib "bbb_merge_yaml '$Y/base.yml' '$Y/secret.yml' '$WORK/m/secret.yml'"
expect_not_contains "merge: does not log values" "$OUT$ERR" "fixturelivekitapisecretnotreal"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
