# Shared entrypoint helper

`entrypoint-lib.sh` is sourced by every image entrypoint (`<component>/docker/entrypoint.sh`).
It implements the common pattern once, so each entrypoint only lists what is specific to
its component.

## The pattern

```
1. validate   bbb_require, bbb_require_secret      missing/placeholder value -> exit 1, naming the variable
2. derive     bbb_default, bbb_feature_enabled     plain bash: URLs, flags from BBB_FEATURES
3. render     bbb_render (envsubst), yq strenv()   write config to "$(bbb_path <bare-metal path>)"
4. merge      bbb_merge_yaml (yq)                  Tier 3 override file, if mounted
5. exec       bbb_exec <command...>                PID 1 is the service; signals reach it
```

Native mechanisms come first: if the component reads env (node-config, Hasura, HOCON
`${?VAR}`, `LIVEKIT_*`), the entrypoint only exports variables and renders nothing.

## Example entrypoint

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=docker/lib/entrypoint-lib.sh
source /usr/local/lib/bbb/entrypoint-lib.sh

bbb_init "$@"
set -- "${BBB_ARGS[@]}"

# 1. validate
bbb_require BBB_DOMAIN
bbb_require_secret TURN_SECRET

# 2. derive
bbb_default BBB_WEB_MAX_HEAP_SIZE 384m
if bbb_feature_enabled recording; then DISABLE_RECORDING_DEFAULT=false; else DISABLE_RECORDING_DEFAULT=true; fi

# 3. render (files with secrets: umask first)
umask 077
bbb_render /usr/local/share/bbb/templates/turn-stun-servers.xml \
    "$(bbb_path /etc/bigbluebutton/turn-stun-servers.xml)"

# 4. merge
bbb_merge_yaml /usr/share/livekit-server/livekit.yaml /etc/bigbluebutton/livekit.yaml \
    "$(bbb_path /run/livekit/livekit.yaml)"

# 5. exec
bbb_exec "$@"
```

`bbb_path` is for **outputs** only. Inputs (templates, image defaults, mounted Tier 3 files)
are read from their real paths, also in render-only mode.

## Functions

| Function | Does | Fails (exit 1) when |
|---|---|---|
| `bbb_require NAME...` | checks each variable is set and non-empty | a variable is unset or empty; the message names it |
| `bbb_require_secret NAME...` | `bbb_require`, then rejects known upstream placeholders (`BBB_SECRET_PLACEHOLDERS`: `changeme secret devkey LIVEKIT_KEY LIVEKIT_SECRET ClueCon`, case-insensitive). An entrypoint may append its own: `BBB_SECRET_PLACEHOLDERS+=(...)` | unset, empty or placeholder; the value is never printed |
| `bbb_default NAME VALUE` | sets NAME to VALUE if unset or empty, and exports it | wrong number of arguments |
| `bbb_feature_enabled NAME` | returns 0 if NAME is an element of comma-separated `BBB_FEATURES` (exact match, spaces ignored), else 1 | — (use it in `if`) |
| `bbb_init [--render-only DIR] [ARGS...]` | selects the mode; puts the remaining arguments in the array `BBB_ARGS` | `--render-only` without DIR |
| `bbb_is_render_only` | returns 0 in render-only mode | — |
| `bbb_path /ABS/PATH` | prints the path, prefixed with DIR in render-only mode | path not absolute |
| `bbb_render TEMPLATE DEST` | substitutes project variables, writes DEST atomically | template missing; a used variable is unset (all missing names listed); an unbraced `$NAME` of a used variable |
| `bbb_merge_yaml BASE OVERRIDE DEST` | deep-merges OVERRIDE into BASE like upstream (`yq eval-all '. as $item ireduce ({}; . * $item)'`): maps merge, arrays and scalars are replaced, BASE key order is kept. Missing OVERRIDE: DEST = BASE | BASE missing; OVERRIDE invalid YAML, not a mapping, or several documents; the message names the file |
| `bbb_exec CMD [ARGS...]` | `exec`s the command; in render-only mode exits 0 without starting it | no command |
| `bbb_log MESSAGE` | prints `<BBB_LOG_TAG>: MESSAGE` to stderr (tag default `entrypoint`) | — |
| `bbb_die MESSAGE` | `bbb_log "ERROR: ..."`, exit 1 | always |

Also set after sourcing: `BBB_TEMPLATE_TOOL=envsubst`, `BBB_RENDER_ROOT` (render-only
directory or empty). `BBB_YQ` selects the yq binary; the default is `yq`, then upstream's
`yq-go`. Names starting with `_bbb_` are internal.

Writes go to a temporary file next to DEST, renamed only on success. A failed render or merge
leaves an existing DEST untouched. File modes follow the umask.

Logging: messages contain variable names and file paths, never variable values or file
contents. The exception is yq's own parse error for an invalid override file (line and column),
which is passed through so admins can find the mistake.

## `--render-only`

`entrypoint.sh --render-only /out` runs validate, derive, render and merge, writes every
output below `/out` at its bare-metal path (`/out/etc/bigbluebutton/...`), and exits 0 at
`bbb_exec`. Golden-file tests and parity checks use it, with the project's fixed test values (never
real secrets). Same env → byte-identical output. Nothing in the helper adds
timestamps, and neither envsubst nor yq does.

Entrypoints must not have side effects outside `bbb_path` before `bbb_exec` (no `chown` of
volumes, no network calls), or must skip them when `bbb_is_render_only` is true.

## Templating rule

The project's single templating tool is **envsubst** (GNU gettext, package `gettext-base`):
a distribution package in every Debian/Ubuntu base, a few hundred kB, and no config file needs
logic inside a template.

- Only **braced upper-case names** are project variables: `${BBB_DOMAIN}`, `${TURN_SECRET}`.
- Everything else is copied unchanged: nginx `$host`, `$remote_addr`, lower-case `${x}`,
  HOCON `${?VAR}`, `${VAR:-default}`, `$$`.
- Every project variable a template uses must be set (it may be empty). Shell variables
  computed in the derive step need not be exported.
- Do not write `$BBB_DOMAIN` without braces in a template that also uses `${BBB_DOMAIN}`; the
  helper refuses it, because envsubst would replace both forms.
- No logic in templates. Conditionals pick values in bash (derive) or pick whole files (render
  this fragment or not). nginx include directories make the second easy.
- YAML and JSON: set values with yq, which quotes them correctly. Do not template them.
  Variables must be exported for `strenv()`:

  ```bash
  export LIVEKIT_API_KEY
  yq -i '.webhook.api_key = strenv(LIVEKIT_API_KEY)' "$(bbb_path /run/livekit/livekit.yaml)"
  ```

The nginx image's own `/etc/nginx/templates` mechanism also uses envsubst, so templates
following this rule work there too.

## Installing the helper in an image

The helper is passed to image builds as a bake named context (`docker-bake.hcl`):

```hcl
target "web" {
  contexts = {
    entrypoint-lib = "./docker/lib"
  }
}
```

```dockerfile
COPY --from=entrypoint-lib entrypoint-lib.sh /usr/local/lib/bbb/entrypoint-lib.sh
# envsubst: only images that render templates; pin the version of the base's release
RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base=<version> \
    && rm -rf /var/lib/apt/lists/*
COPY docker/entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

Runtime requirements: bash ≥ 4.4, coreutils; `envsubst` for `bbb_render`; mikefarah/yq v4 for
`bbb_merge_yaml`. Install yq exactly as upstream pins it: version from
`build/packages-template/bbb-yq-go/build.sh`, verified against `bbb-yq-go.sha256sum`
(see `docker/tests/lib/Dockerfile`).

Images without bash (e.g. Alpine or distroless) cannot use the helper. They use their
component's native env support only.

## Tests

```bash
docker/tests/lib/run.sh                     # docker if installed, else podman
CONTAINER_ENGINE=podman docker/tests/lib/run.sh
```

`run.sh` builds `docker/tests/lib/Dockerfile` (pinned ubuntu:24.04, envsubst, yq as upstream)
and runs:
- `test-entrypoint-lib.sh`: the interface contract. Do not change it to make the helper pass.
- `test-entrypoint-lib-extra.sh`: additional behaviour.
