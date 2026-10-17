#!/usr/bin/env bash
# Additional tests for docker/tests/golden/run-golden.sh, beyond the interface tests in
# test-golden.sh: images running as a non-root user, files with restrictive modes, symlinks,
# cleanup of the runner's temporary files, no image pulls, and parity edge cases.
#
# Usage: docker/tests/golden/test-golden-extra.sh   (after test-golden.sh, which builds the
#        selftest image; run.sh runs both)

# `$host` below is a literal nginx variable, not a shell expansion.
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${RUN_GOLDEN:-$HERE/run-golden.sh}"
ENGINE="${CONTAINER_ENGINE:-$(command -v docker >/dev/null 2>&1 && echo docker || echo podman)}"
BASE_IMAGE=localhost/bbb-golden-selftest:test
IMAGE=localhost/bbb-golden-selftest-extra:test
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "ok   $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL $1${2:+: $2}"; }

[ -x "$RUNNER" ] || { echo "runner not found or not executable: $RUNNER"; exit 1; }
"$ENGINE" image inspect "$BASE_IMAGE" >/dev/null 2>&1 ||
    "$ENGINE" build -q -t "$BASE_IMAGE" -f "$HERE/selftest-image/Dockerfile" "$HERE/../.." >/dev/null

# Derived image: runs as nobody and, after the selftest entrypoint, adds a symlink and a 0600
# file below the render-only directory (as an image rendering a secret file would).
mkdir -p "$WORK/ctx"
cat >"$WORK/ctx/wrapper.sh" <<'EOF'
#!/usr/bin/env bash
# `$host` below is a literal nginx variable, not a shell expansion.
# shellcheck disable=SC2016

set -euo pipefail
/usr/local/bin/entrypoint.sh "$@"
out="$2/etc/selftest"
ln -s app.conf "$out/link.conf"
( umask 077; printf 'secret=%s\n' "${SELFTEST_SECRET:-none}" >"$out/secret.conf" )
mkdir -p "$out/private"
chmod 0700 "$out/private"
printf 'x\n' >"$out/private/file"
EOF
cat >"$WORK/ctx/Dockerfile" <<EOF
FROM $BASE_IMAGE
COPY wrapper.sh /usr/local/bin/wrapper.sh
RUN chmod 0755 /usr/local/bin/wrapper.sh
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/wrapper.sh"]
EOF
"$ENGINE" build -q -t "$IMAGE" "$WORK/ctx" >/dev/null

ROOT="$WORK/golden"
mkdir -p "$ROOT"
newcase() { # name image [env lines...]
    local d="$ROOT/$1"; shift
    mkdir -p "$d"
    printf '%s\n' "$1" >"$d/image"; shift
    printf '%s\n' "$@" >"$d/fixture.env"
}
RUN_TMP="$WORK/tmp"
mkdir -p "$RUN_TMP"
run() {
    set +e
    TMPDIR="$RUN_TMP" "$RUNNER" --engine "$ENGINE" --root "$ROOT" "$@" >"$WORK/out" 2>&1
    RC=$?
    set -e
    OUT="$(cat "$WORK/out")"
}
expect_rc() { if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1" "exit $RC, expected $2; output: $OUT"; fi; }
expect_line() { if grep -qE "$2" "$WORK/out"; then pass "$1"; else fail "$1" "no line /$2/ in: $OUT"; fi; }
expect_no_line() { if grep -qE "$2" "$WORK/out"; then fail "$1" "unexpected line /$2/ in: $OUT"; else pass "$1"; fi; }

# --- non-root image, modes, symlinks, cleanup --------------------------------------------------
newcase nonroot "$IMAGE" BBB_DOMAIN=bbb.example.com SELFTEST_SECRET=fixturesecret
run --update nonroot
expect_rc "non-root image: --update creates expected/: exit 0" 0
expect_line "non-root image: UPDATED" "^UPDATED nonroot$"
exp="$ROOT/nonroot/expected/etc/selftest"
if [ -L "$exp/link.conf" ] && [ "$(readlink "$exp/link.conf")" = app.conf ]; then
    pass "symlink kept as a symlink"
else
    fail "symlink kept as a symlink" "$(ls -l "$exp" 2>&1)"
fi
if grep -qx 'secret=fixturesecret' "$exp/secret.conf" 2>/dev/null; then
    pass "0600 file written by another UID is readable"
else
    fail "0600 file written by another UID is readable"
fi
if [ -z "$(find "$ROOT/nonroot/expected" ! -user "$(id -u)" -print -quit)" ]; then
    pass "expected/ is owned by the invoking user"
else
    fail "expected/ is owned by the invoking user" "$(find "$ROOT/nonroot/expected" -ls)"
fi
if [ -z "$(find "$RUN_TMP" -mindepth 1 -print -quit)" ]; then
    pass "runner leaves no temporary files"
else
    fail "runner leaves no temporary files" "$(find "$RUN_TMP" -ls)"
fi

run nonroot
expect_rc "non-root image: second run passes" 0

ln -sfn other.conf "$exp/link.conf"
run nonroot
expect_line "symlink target change: reported" "^FAIL nonroot: differs: etc/selftest/link.conf$"
ln -sfn app.conf "$exp/link.conf"

if rm -rf "$ROOT/nonroot/expected"; then pass "expected/ can be deleted by the user"; else fail "expected/ can be deleted by the user"; fi

# --- content diff excerpt ----------------------------------------------------------------------
newcase excerpt "$BASE_IMAGE" BBB_DOMAIN=bbb.example.com
run --update excerpt
sed -i 's/workers=4/workers=5/' "$ROOT/excerpt/expected/etc/selftest/app.conf"
run excerpt
expect_line "differs: diff excerpt indented by two spaces" "^  -workers=5$"
expect_line "differs: diff excerpt shows the rendered line" "^  \+workers=4$"

# --- usage and environment ---------------------------------------------------------------------
newcase noenv "$BASE_IMAGE"
rm "$ROOT/noenv/fixture.env"
run noenv
expect_rc "missing fixture.env: exit 2" 2
rm -rf "$ROOT/noenv"

mkdir -p "$ROOT/noimage"
run noimage
expect_rc "explicit NAME without image file: exit 2" 2
run
expect_no_line "no NAME: directories without image are not cases" "noimage"
rm -rf "$ROOT/noimage"

run --engine nerdctl excerpt
expect_rc "unsupported engine: exit 2" 2

newcase nopull localhost/bbb-golden-no-such-image:never BBB_DOMAIN=bbb.example.com
run nopull
expect_line "image not present locally: render fails, no pull" "^FAIL nopull: render: exit [1-9]"
rm -rf "$ROOT/nopull"

# --- parity edge cases -------------------------------------------------------------------------
newcase par "$BASE_IMAGE" BBB_DOMAIN=bbb.example.com
run --update par
mkdir -p "$ROOT/par/ref/selftest"
printf '%s\n' '# selftest config (fixture)' 'server_name bbb.example.com;' 'workers=4' \
    'proxy_set_header Host $host;' 'listen 80;' >"$ROOT/par/ref/selftest/app.conf"
parity_yaml() {
    printf '%s\n' 'reference: ref' 'files:' '  - {rendered: etc/selftest/app.conf, reference: selftest/app.conf}' \
        'allowed:' "$@" >"$ROOT/par/parity.yaml"
}

run --parity par
expect_line "--parity without parity.yaml: skipped" "^PARITY-SKIP par: "
expect_rc "--parity without parity.yaml: exit 0" 0

parity_yaml '  []'
run --parity par
expect_line "line only in the reference: reported" "^PARITY-FAIL par: etc/selftest/app.conf: unlisted difference: listen 80;$"

parity_yaml '  - {file: etc/selftest/app.conf, line: "^listen ", reason: "bare metal listens directly"}'
run --parity par
expect_line "line only in the reference, allowlisted: PARITY-PASS" "^PARITY-PASS par$"

parity_yaml '  - {file: etc/selftest/app.conf, line: "^listen (", reason: "broken"}'
run --parity par
expect_line "invalid ERE: reported" "^PARITY-FAIL par: allowlist: invalid ERE: \^listen \($"

parity_yaml '  - {file: etc/selftest/other.conf, line: "^listen ", reason: "wrong file"}'
run --parity par
expect_line "entry for another file does not match" "^PARITY-FAIL par: etc/selftest/app.conf: unlisted difference: listen 80;$"
expect_line "entry for another file: unused" "^PARITY-FAIL par: allowlist: unused entry: \^listen $"

printf '%s\n' 'reference: ref' 'files:' '  - {rendered: etc/selftest/app.conf, reference: selftest/missing.conf}' \
    >"$ROOT/par/parity.yaml"
run --parity par
expect_line "reference file missing: reported" "^PARITY-FAIL par: etc/selftest/app.conf: reference missing: selftest/missing.conf$"

printf '%s\n' 'reference: ref' 'files:' '  - {rendered: etc/selftest/nope.conf, reference: selftest/app.conf}' \
    >"$ROOT/par/parity.yaml"
run --parity par
expect_line "rendered file missing: reported" "^PARITY-FAIL par: etc/selftest/nope.conf: not rendered$"

printf '%s\n' 'files: [' >"$ROOT/par/parity.yaml"
run --parity par
expect_line "invalid parity.yaml: reported" "^PARITY-FAIL par: parity.yaml: "
expect_rc "invalid parity.yaml: exit 1" 1

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
