# shellcheck shell=bash
#
# Shared helper for BigBlueButton image entrypoints.
#
# Sourced, never executed. Every entrypoint follows the same five steps:
#
#   validate  bbb_require / bbb_require_secret
#   derive    bbb_default, bbb_feature_enabled, plain bash
#   render    bbb_render (envsubst) into bbb_path <bare-metal path>
#   merge     bbb_merge_yaml (yq) with the Tier 3 override file, if mounted
#   exec      bbb_exec <command...>
#
# `bbb_init --render-only <dir>` runs steps 1-4 with every bbb_path below <dir> and makes
# bbb_exec exit 0 instead of starting the process (golden-file tests, parity checks).
#
# Works under `set -euo pipefail`. Messages go to stderr and name variables, never their
# values. See docker/lib/README.md.

# Variables below are read by the entrypoints that source this file.
# shellcheck disable=SC2034

# The project-wide templating tool. Templates use its syntax: ${NAME} only.
BBB_TEMPLATE_TOOL=envsubst

# Values shipped upstream as stand-ins for real credentials. bbb_require_secret rejects them.
# Entrypoints may append component-specific ones before validating.
BBB_SECRET_PLACEHOLDERS=(changeme secret devkey LIVEKIT_KEY LIVEKIT_SECRET ClueCon)

# Set by bbb_init: render-only root (empty = normal mode) and the arguments left after the
# mode option.
BBB_RENDER_ROOT=""
BBB_ARGS=()

# --- logging -----------------------------------------------------------------------------

# Log to stderr. Callers pass variable names and file paths, never variable values.
bbb_log() {
    printf '%s: %s\n' "${BBB_LOG_TAG:-entrypoint}" "$*" >&2
}

# Log an error and exit 1.
bbb_die() {
    bbb_log "ERROR: $*"
    exit 1
}

_bbb_check_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || bbb_die "invalid variable name: $1"
}

# --- validate ----------------------------------------------------------------------------

# bbb_require NAME... — each variable must be set and non-empty.
bbb_require() {
    local var_name
    for var_name in "$@"; do
        _bbb_check_name "$var_name"
        [ -n "${!var_name:-}" ] || bbb_die "required variable $var_name is not set or empty"
    done
}

# bbb_require_secret NAME... — like bbb_require, and the value must not be a known upstream
# placeholder (compared case-insensitively).
bbb_require_secret() {
    local var_name placeholder
    for var_name in "$@"; do
        bbb_require "$var_name"
        for placeholder in "${BBB_SECRET_PLACEHOLDERS[@]}"; do
            if [ "${!var_name,,}" = "${placeholder,,}" ]; then
                bbb_die "$var_name is set to a known upstream placeholder; set a generated secret"
            fi
        done
    done
}

# --- derive ------------------------------------------------------------------------------

# bbb_default NAME VALUE — set and export NAME to VALUE if it is unset or empty.
bbb_default() {
    [ "$#" -eq 2 ] || bbb_die "usage: bbb_default NAME VALUE"
    _bbb_check_name "$1"
    if [ -z "${!1:-}" ]; then
        printf -v "$1" '%s' "$2"
    fi
    export "${1?}"
}

# bbb_feature_enabled NAME — true if NAME is an element of the comma-separated BBB_FEATURES.
bbb_feature_enabled() {
    if [ "$#" -ne 1 ] || [ -z "$1" ]; then bbb_die "usage: bbb_feature_enabled NAME"; fi
    local features="${BBB_FEATURES:-}"
    features="${features// /}"
    case ",$features," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- mode and paths ----------------------------------------------------------------------

# bbb_init [--render-only DIR] [ARGS...] — select the mode. The remaining arguments are left
# in the array BBB_ARGS, so an entrypoint can do:  bbb_init "$@"; set -- "${BBB_ARGS[@]}"
bbb_init() {
    BBB_RENDER_ROOT=""
    if [ "${1:-}" = "--render-only" ]; then
        [ -n "${2:-}" ] || bbb_die "--render-only needs a directory"
        BBB_RENDER_ROOT="${2%/}"
        [ -n "$BBB_RENDER_ROOT" ] || bbb_die "--render-only directory must not be /"
        mkdir -p "$BBB_RENDER_ROOT" || bbb_die "cannot create render-only directory $BBB_RENDER_ROOT"
        shift 2
    fi
    BBB_ARGS=("$@")
}

# bbb_is_render_only — true in render-only mode.
bbb_is_render_only() {
    [ -n "$BBB_RENDER_ROOT" ]
}

# bbb_path ABSOLUTE_PATH — print where a config file goes: the path itself in normal mode,
# the path below the render-only directory in render-only mode.
bbb_path() {
    [ "$#" -eq 1 ] || bbb_die "usage: bbb_path ABSOLUTE_PATH"
    case "$1" in
        /*) ;;
        *) bbb_die "bbb_path needs an absolute path: $1" ;;
    esac
    printf '%s\n' "$BBB_RENDER_ROOT$1"
}

_bbb_require_file() { # PATH DESCRIPTION
    if [ ! -f "$1" ] || [ ! -r "$1" ]; then bbb_die "$2 $1 not found or not readable"; fi
}

# _bbb_write DEST COMMAND [ARGS...] — write the command's stdout to DEST atomically: a
# temporary file in the same directory, renamed only if the command succeeded. The file mode
# follows the umask; entrypoints writing secrets set `umask 077` first.
_bbb_write() {
    local dest_path="$1" dest_dir tmp_path
    shift
    dest_dir="$(dirname "$dest_path")"
    mkdir -p "$dest_dir" || bbb_die "cannot create directory $dest_dir"
    tmp_path="$dest_path.tmp.$$"
    rm -f "$tmp_path"
    if ! "$@" >"$tmp_path"; then
        rm -f "$tmp_path"
        return 1
    fi
    mv -f "$tmp_path" "$dest_path" || bbb_die "cannot write $dest_path"
}

# --- render ------------------------------------------------------------------------------

# bbb_render TEMPLATE DEST — substitute project variables in TEMPLATE, write DEST.
#
# Only braced upper-case names (${BBB_DOMAIN}) are project variables. Everything else,
# including nginx variables such as $host and HOCON ${?VAR}, is copied unchanged. Every
# project variable used by the template must be set (empty is allowed); otherwise nothing is
# written and the missing names are reported. Shell variables need not be exported.
bbb_render() {
    [ "$#" -eq 2 ] || bbb_die "usage: bbb_render TEMPLATE DEST"
    local tpl_path="$1" dest_path="$2"
    _bbb_require_file "$tpl_path" template
    command -v envsubst >/dev/null 2>&1 || bbb_die "envsubst not found (install gettext-base)"

    local content rest var_name unbraced
    local braced='\$\{([A-Z][A-Z0-9_]*)\}'
    content="$(<"$tpl_path")"

    # Collect the project variable names used by the template, in order of appearance.
    local -A seen=()
    local names=()
    rest="$content"
    while [[ "$rest" =~ $braced ]]; do
        var_name="${BASH_REMATCH[1]}"
        rest="${rest#*"${BASH_REMATCH[0]}"}"
        if [ -z "${seen[$var_name]:-}" ]; then
            seen[$var_name]=1
            names+=("$var_name")
        fi
    done

    local missing=()
    for var_name in "${names[@]}"; do
        [ -n "${!var_name+set}" ] || missing+=("$var_name")
        # envsubst would also replace the unbraced form; refuse it so the rule stays simple.
        unbraced='\$'"$var_name"'([^A-Za-z0-9_]|$)'
        if [[ "$content" =~ $unbraced ]]; then
            bbb_die "template $tpl_path uses \$$var_name without braces; write \${$var_name}"
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        bbb_die "template $tpl_path uses undefined variable(s): ${missing[*]}"
    fi

    if [ "${#names[@]}" -eq 0 ]; then
        _bbb_write "$dest_path" cat "$tpl_path" || bbb_die "cannot write $dest_path"
    else
        _bbb_write "$dest_path" _bbb_envsubst "$tpl_path" "${names[@]}" \
            || bbb_die "rendering $tpl_path failed"
    fi
    bbb_log "rendered $dest_path"
}

# _bbb_envsubst TEMPLATE NAME... — envsubst restricted to the given names. Runs in a subshell,
# so exporting the names does not change the caller's environment.
_bbb_envsubst() (
    local tpl_path="$1" format="" var_name
    shift
    for var_name in "$@"; do
        export "${var_name?}"
        format+="\${$var_name} "
    done
    envsubst "$format" <"$tpl_path"
)

# --- merge -------------------------------------------------------------------------------

# Resolve the yq binary once, in the current shell (not in a command substitution, so a
# missing yq stops the entrypoint).
_bbb_find_yq() {
    if [ -n "${BBB_YQ:-}" ]; then return 0; fi
    if command -v yq >/dev/null 2>&1; then BBB_YQ=yq
    elif command -v yq-go >/dev/null 2>&1; then BBB_YQ=yq-go # upstream package name
    else bbb_die "yq (mikefarah/yq v4) not found"
    fi
}

_bbb_yq() {
    "$BBB_YQ" "$@"
}

# bbb_merge_yaml BASE OVERRIDE DEST — deep-merge OVERRIDE into BASE and write DEST, the same
# way upstream packaging does (yq `. * $item`): maps merge, arrays and scalars are replaced,
# key order of BASE is kept. A missing OVERRIDE is not an error: DEST is a copy of BASE. An
# OVERRIDE that is not valid YAML, or not a single mapping, is an error naming the file.
bbb_merge_yaml() {
    [ "$#" -eq 3 ] || bbb_die "usage: bbb_merge_yaml BASE OVERRIDE DEST"
    local base_path="$1" override_path="$2" dest_path="$3" kind
    _bbb_require_file "$base_path" "base file"
    _bbb_find_yq

    if [ ! -e "$override_path" ]; then
        _bbb_write "$dest_path" cat "$base_path" || bbb_die "cannot write $dest_path"
        bbb_log "no override $override_path; using $base_path"
        return 0
    fi
    _bbb_require_file "$override_path" "override file"

    kind="$(_bbb_yq eval-all 'tag' "$override_path")" \
        || bbb_die "override file $override_path is not valid YAML"
    case "$kind" in
        "" | "!!map" | "!!null") ;;
        *) bbb_die "override file $override_path must contain a single YAML mapping" ;;
    esac

    # shellcheck disable=SC2016 # a yq expression, not shell
    _bbb_write "$dest_path" _bbb_yq eval-all '. as $item ireduce ({}; . * $item)' "$base_path" "$override_path" \
        || bbb_die "merging $override_path into $base_path failed"
    bbb_log "merged $override_path into $dest_path"
}

# --- exec --------------------------------------------------------------------------------

# bbb_exec COMMAND [ARGS...] — replace the shell with the main process. In render-only mode,
# exit 0 instead: the configuration is written, nothing is started.
bbb_exec() {
    [ "$#" -gt 0 ] || bbb_die "usage: bbb_exec COMMAND [ARGS...]"
    if bbb_is_render_only; then
        bbb_log "render-only: configuration written below $BBB_RENDER_ROOT; process not started"
        exit 0
    fi
    exec "$@"
}
