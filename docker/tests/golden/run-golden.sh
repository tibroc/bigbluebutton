#!/usr/bin/env bash
# Golden-file runner: renders each image's configuration with `--render-only` and the fixture
# env, and compares it with the committed expected tree (and, with --parity, with the
# bare-metal reference). The interface is fixed by test-golden.sh (protected); see its header.
#
# Usage: run-golden.sh [--engine podman|docker] [--root DIR] [--update] [--parity] [NAME...]
#   --engine   container engine (default: $CONTAINER_ENGINE, else docker if installed, else podman)
#   --root     golden root, one directory per case (default: the directory of this script)
#   --update   replace each case's expected/ with the rendered tree
#   --parity   also compare with the reference tree named in the case's parity.yaml
#   NAME       cases to run (default: every directory below --root that contains `image`)
#
# Case directory: image (one line, image reference), fixture.env (env file), expected/,
# parity.yaml (optional). Each render is
#   <engine> run --rm --pull=never --network=none --env-file fixture.env \
#       -v <tmp>:/golden-out[:Z] IMAGE --render-only /golden-out
# The image must exist locally (never pulled); rendering must not need the network.
# `:Z` is added when SELinux is enabled on the host.
#
# Files written by the container: the mount directory is world-writable (inside a private
# 0700 temporary directory), so images running as a non-root user can write to it. Files the
# container leaves owned by another host UID are handed back before they are compared:
#   rootless podman   `podman unshare chown -R 0:0` (container root is the invoking user)
#   rootless docker   helper container `chown -R 0:0` (same mapping)
#   rootful engines   helper container `chown -R <uid>:<gid>` of the invoking user
# The helper is the pinned ubuntu:24.04 base used by the test images. Nothing is left behind
# that the user cannot delete; the temporary directory is removed on exit.
#
# Comparison covers regular files (content) and symlinks (target); file modes are not compared.
# yq (mikefarah v4, `yq` or `yq-go` in PATH) is needed only for --parity.
#
# Exit: 0 everything passed, 1 any FAIL or PARITY-FAIL, 2 usage or environment error.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ubuntu:24.04, the same digest as the other test images.
HELPER_IMAGE=docker.io/library/ubuntu@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
DIFF_LINES=12

usage() {
    sed -n '6,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    [ -n "${1:-}" ] && echo "error: $1" >&2
    exit 2
}
die_env() { echo "error: $1" >&2; exit 2; }

ENGINE="${CONTAINER_ENGINE:-}"
ROOT="$HERE"
UPDATE=0
PARITY=0
NAMES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --engine) [ $# -ge 2 ] || usage "--engine needs a value"; ENGINE="$2"; shift 2 ;;
        --root) [ $# -ge 2 ] || usage "--root needs a value"; ROOT="$2"; shift 2 ;;
        --update) UPDATE=1; shift ;;
        --parity) PARITY=1; shift ;;
        -h | --help) usage ;;
        --) shift; NAMES+=("$@"); break ;;
        -*) usage "unknown option: $1" ;;
        *) NAMES+=("$1"); shift ;;
    esac
done

if [ -z "$ENGINE" ]; then
    if command -v docker >/dev/null 2>&1; then ENGINE=docker; else ENGINE=podman; fi
fi
case "$ENGINE" in
    docker | podman) ;;
    *) usage "--engine must be podman or docker, got '$ENGINE'" ;;
esac
command -v "$ENGINE" >/dev/null 2>&1 || die_env "$ENGINE not found"
[ -d "$ROOT" ] || usage "golden root is not a directory: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"

# --- cases -------------------------------------------------------------------------------------
if [ "${#NAMES[@]}" -eq 0 ]; then
    while IFS= read -r -d '' f; do
        NAMES+=("$(basename "$(dirname "$f")")")
    done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -name image -type f -print0 | LC_ALL=C sort -z)
fi
for name in ${NAMES[@]+"${NAMES[@]}"}; do
    case "$name" in '' | . | .. | */*) usage "invalid case name: '$name'" ;; esac
    [ -d "$ROOT/$name" ] || usage "unknown case: $name"
    [ -f "$ROOT/$name/image" ] || usage "case $name has no image file"
    [ -f "$ROOT/$name/fixture.env" ] || usage "case $name has no fixture.env file"
done

YQ=""
if [ "$PARITY" -eq 1 ]; then
    for c in yq yq-go; do
        if command -v "$c" >/dev/null 2>&1; then YQ="$c"; break; fi
    done
    [ -n "$YQ" ] || die_env "--parity needs yq (mikefarah v4) in PATH; docker/tests/golden/run.sh provides it"
fi

MOUNT_OPT=""
if [ -e /sys/fs/selinux/enforce ]; then MOUNT_OPT=":Z"; fi

ROOTLESS=""
engine_rootless() {
    if [ -z "$ROOTLESS" ]; then
        if [ "$ENGINE" = podman ]; then
            ROOTLESS="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo false)"
        elif docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q 'name=rootless'; then
            ROOTLESS=true
        else
            ROOTLESS=false
        fi
    fi
    [ "$ROOTLESS" = true ]
}

WORK="$(mktemp -d)"
chmod 0700 "$WORK"
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
    # Last resort for files a failed hand-back left behind.
    rm -rf "$WORK" 2>/dev/null || {
        reclaim "$WORK" >/dev/null 2>&1 || true
        rm -rf "$WORK" 2>/dev/null || echo "warning: could not remove $WORK" >&2
    }
}
trap cleanup EXIT

# reclaim DIR: make every file below DIR owned by, readable and deletable for the invoking user.
reclaim() {
    local dir="$1" uid gid
    uid="$(id -u)"
    gid="$(id -g)"
    if [ -n "$(find "$dir" ! -user "$uid" -print -quit 2>/dev/null)" ]; then
        if engine_rootless && [ "$ENGINE" = podman ]; then
            podman unshare chown -R 0:0 "$dir"
        elif engine_rootless; then
            "$ENGINE" run --rm --network=none --user 0:0 -v "$dir:/golden-out$MOUNT_OPT" \
                "$HELPER_IMAGE" chown -R 0:0 /golden-out >/dev/null
        else
            "$ENGINE" run --rm --network=none --user 0:0 -v "$dir:/golden-out$MOUNT_OPT" \
                "$HELPER_IMAGE" chown -R "$uid:$gid" /golden-out >/dev/null
        fi
    fi
    chmod -R u+rwX "$dir"
}

# render IMAGE ENVFILE OUTDIR LOG -> exit code of the container
render() {
    local image="$1" envfile="$2" out="$3" log="$4" rc=0
    mkdir -p "$out"
    chmod 0777 "$out"
    "$ENGINE" run --rm --pull=never --network=none --env-file "$envfile" \
        -v "$out:/golden-out$MOUNT_OPT" "$image" --render-only /golden-out >"$log" 2>&1 || rc=$?
    reclaim "$out" >>"$log" 2>&1 || { echo "cannot reclaim rendered files in $out" >>"$log"; [ "$rc" -ne 0 ] || rc=125; }
    return "$rc"
}

# list_tree DIR: relative paths of regular files and symlinks, NUL-separated, sorted.
list_tree() {
    [ -d "$1" ] || return 0
    (cd "$1" && find . \( -type f -o -type l \) -print0 | sed -z 's|^\./||' | LC_ALL=C sort -z)
}

# same_entry A B: 0 if both are the same symlink target or regular files with equal content.
same_entry() {
    if [ -L "$1" ] || [ -L "$2" ]; then
        [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
    else
        cmp -s "$1" "$2"
    fi
}

# tree_join A B: "<1|2|3>\t<relpath>" NUL-separated; 1 only in A, 2 only in B, 3 in both.
tree_join() {
    LC_ALL=C comm -z <(list_tree "$1") <(list_tree "$2") |
        while IFS= read -r -d '' line; do
            case "$line" in
                $'\t\t'*) printf '3\t%s\0' "${line#$'\t\t'}" ;;
                $'\t'*) printf '2\t%s\0' "${line#$'\t'}" ;;
                *) printf '1\t%s\0' "$line" ;;
            esac
        done
}

FAILED=0
CASE=""
CASE_FAILED=0
fail() { # detail
    echo "FAIL $CASE: $1"
    CASE_FAILED=1
    FAILED=1
}
indent() { sed 's/^/  /'; }

EXPECTED=""
RENDERED=""
on_golden() {
    case "$1" in
        only-a) fail "missing: $2" ;;
        only-b) fail "unexpected: $2" ;;
        differs)
            fail "differs: $2"
            if [ -f "$EXPECTED/$2" ] && [ -f "$RENDERED/$2" ] && [ ! -L "$EXPECTED/$2" ] && [ ! -L "$RENDERED/$2" ]; then
                diff -u "$EXPECTED/$2" "$RENDERED/$2" | tail -n +3 | head -n "$DIFF_LINES" | indent || true
            fi
            ;;
    esac
}

# --- parity ------------------------------------------------------------------------------------
PARITY_FAILED=0
parity_fail() {
    echo "PARITY-FAIL $CASE: $1"
    PARITY_FAILED=1
    FAILED=1
}

# yq_lines EXPR FILE: one output line per result (null/absent -> empty string).
yq_lines() { "$YQ" -r "$1" "$2"; }

parity_check() {
    local dir="$1" rendered_root="$2" pfile="$1/parity.yaml"
    PARITY_FAILED=0
    if [ ! -f "$pfile" ]; then
        echo "PARITY-SKIP $CASE: no parity.yaml"
        return 0
    fi
    local err
    if ! err="$("$YQ" -e 'tag == "!!map"' "$pfile" 2>&1 >/dev/null)"; then
        parity_fail "parity.yaml: not a YAML mapping${err:+ ($(printf '%s' "$err" | head -n 1))}"
        return 0
    fi
    local ref nfiles nallowed
    ref="$(yq_lines '.reference // ""' "$pfile")"
    nfiles="$(yq_lines '(.files // []) | length' "$pfile")"
    nallowed="$(yq_lines '(.allowed // []) | length' "$pfile")"
    if [ -z "$ref" ]; then parity_fail "parity.yaml: no reference"; return 0; fi
    if [ "$nfiles" -eq 0 ]; then parity_fail "parity.yaml: no files"; return 0; fi
    case "$ref" in /*) ;; *) ref="$dir/$ref" ;; esac
    [ -d "$ref" ] || { parity_fail "parity.yaml: reference is not a directory: $(yq_lines '.reference' "$pfile")"; return 0; }

    local -a a_file a_line a_used
    local i j
    for ((i = 0; i < nallowed; i++)); do
        a_file[i]="$(yq_lines ".allowed[$i].file // \"\"" "$pfile")"
        a_line[i]="$(yq_lines ".allowed[$i].line // \"\"" "$pfile")"
        a_used[i]=0
        local reason
        reason="$(yq_lines ".allowed[$i].reason // \"\"" "$pfile" | tr -d '[:space:]')"
        if [ -z "${a_file[i]}" ] || [ -z "${a_line[i]}" ]; then
            parity_fail "allowlist: entry $((i + 1)) needs file and line"
            a_file[i]=""
            continue
        fi
        [ -n "$reason" ] || parity_fail "allowlist: missing reason: ${a_line[i]}"
        local rc=0
        # shellcheck disable=SC2319 # the status of =~ is wanted: 2 means an invalid ERE
        [[ "" =~ ${a_line[i]} ]] || rc=$?
        if [ "$rc" -eq 2 ]; then
            parity_fail "allowlist: invalid ERE: ${a_line[i]}"
            a_file[i]=""
        fi
    done

    local rendered reference line matched
    for ((j = 0; j < nfiles; j++)); do
        rendered="$(yq_lines ".files[$j].rendered // \"\"" "$pfile")"
        reference="$(yq_lines ".files[$j].reference // \"\"" "$pfile")"
        if [ -z "$rendered" ] || [ -z "$reference" ]; then
            parity_fail "parity.yaml: files entry $((j + 1)) needs rendered and reference"
            continue
        fi
        if [ ! -f "$rendered_root/$rendered" ]; then parity_fail "$rendered: not rendered"; continue; fi
        if [ ! -f "$ref/$reference" ]; then parity_fail "$rendered: reference missing: $reference"; continue; fi
        # Every line only on one side (reference: -, rendered: +), without the marker.
        while IFS= read -r line; do
            matched=0
            for ((i = 0; i < nallowed; i++)); do
                [ "${a_file[i]}" = "$rendered" ] || continue
                if [[ "$line" =~ ${a_line[i]} ]]; then
                    matched=1
                    a_used[i]=1
                fi
            done
            [ "$matched" -eq 1 ] || parity_fail "$rendered: unlisted difference: $line"
        done < <(diff --unchanged-line-format= --old-line-format='%L' --new-line-format='%L' \
            "$ref/$reference" "$rendered_root/$rendered" || true)
    done
    for ((i = 0; i < nallowed; i++)); do
        if [ -n "${a_file[i]}" ] && [ "${a_used[i]}" -eq 0 ]; then
            parity_fail "allowlist: unused entry: ${a_line[i]}"
        fi
    done
    [ "$PARITY_FAILED" -eq 1 ] || echo "PARITY-PASS $CASE"
}

# --- run ---------------------------------------------------------------------------------------
for CASE in ${NAMES[@]+"${NAMES[@]}"}; do
    CASE_FAILED=0
    dir="$ROOT/$CASE"
    image="$(head -n 1 "$dir/image" | tr -d '[:space:]')"
    [ -n "$image" ] || { fail "render: empty image file"; continue; }
    w="$WORK/$CASE"
    mkdir -p "$w"
    rc=0
    render "$image" "$dir/fixture.env" "$w/r1" "$w/r1.log" || rc=$?
    if [ "$rc" -eq 0 ]; then render "$image" "$dir/fixture.env" "$w/r2" "$w/r2.log" || rc=$?; fi
    if [ "$rc" -ne 0 ]; then
        fail "render: exit $rc"
        tail -n 20 "$w/r1.log" "$w/r2.log" 2>/dev/null | grep -v '^==>' | indent || true
        continue
    fi

    while IFS=$'\t' read -r -d '' kind path; do
        if [ "$kind" != 3 ] || ! same_entry "$w/r1/$path" "$w/r2/$path"; then fail "nondeterministic: $path"; fi
    done < <(tree_join "$w/r1" "$w/r2")
    [ "$CASE_FAILED" -eq 0 ] || continue

    if [ "$UPDATE" -eq 1 ]; then
        rm -rf "$dir/expected"
        cp -R "$w/r1" "$dir/expected"
        chmod 0755 "$dir/expected"
        echo "UPDATED $CASE"
    fi

    EXPECTED="$dir/expected"
    RENDERED="$w/r1"
    while IFS=$'\t' read -r -d '' kind path; do
        case "$kind" in
            1) on_golden only-a "$path" ;;
            2) on_golden only-b "$path" ;;
            3) same_entry "$EXPECTED/$path" "$RENDERED/$path" || on_golden differs "$path" ;;
        esac
    done < <(tree_join "$EXPECTED" "$RENDERED")
    [ "$CASE_FAILED" -eq 1 ] || echo "PASS $CASE"

    if [ "$PARITY" -eq 1 ]; then parity_check "$dir" "$w/r1"; fi
done

exit "$FAILED"
