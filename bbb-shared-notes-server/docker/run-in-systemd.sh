#!/usr/bin/env bash
# run-in-systemd.sh — container replacement for bbb-shared-notes-server/run-in-systemd.sh.
#
# Usage:  run-in-systemd.sh <timeout-seconds> <command> [args …]
#
# The PDF export runs wkhtmltopdf through the script named in commandExecution.runnerScript of
# config/default.yml (src/express/handlers/exportDocumentToPdf.ts), so the image keeps the
# path and the argument contract. On bare metal the script starts a hardened transient unit of
# the bigbluebutton user's systemd instance. A container has no systemd user manager; it is
# the sandbox itself (own root filesystem, non-root user, the memory limit of the service).
# What does not need systemd is kept:
#
#   RuntimeMaxSec=<timeout>     timeout(1); SIGKILL if the command ignores SIGTERM
#   WorkingDirectory=           the command runs in BBB_BLOCKNOTE_DIR (same default)
#   UMask=0022                  umask 0022
#   PrivateNetwork=true,        an unreachable HTTP(S) proxy (wkhtmltopdf uses the *_proxy
#   IPAddressDeny=any           variables), so the HTML cannot make it fetch from other hosts.
#                               Qt does not proxy loopback addresses: unlike on bare metal, the
#                               command can still reach the server itself on 127.0.0.1:8787.
#
# MemoryHigh/MemoryMax need cgroups; the memory limit of the service applies instead (an
# address-space limit, ulimit -v, makes wkhtmltopdf's WebKit crash at start). ProtectSystem,
# ProtectHome, PrivateTmp, NoNewPrivileges and the mount syscall filter are covered by the
# container: the image is root-owned, the service runs without privileges, and only /tmp and
# the rendered config are writable.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <timeout-seconds> <command> [args …]" >&2
  exit 1
fi

timeout_secs="$1"; shift

: "${BBB_BLOCKNOTE_DIR:=/tmp/shared-notes-dropbox/}"

cd "$BBB_BLOCKNOTE_DIR"
umask 0022

# Port 9 (discard) on loopback: nothing listens there, every proxied request fails at once.
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
  HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
unset no_proxy NO_PROXY

exec timeout --kill-after=10s "${timeout_secs}" "$@"
