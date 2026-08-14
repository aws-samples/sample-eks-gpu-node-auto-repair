#!/usr/bin/env bash
# Shared helpers for the g6e overlay scripts.
set -euo pipefail

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  # require <command> ... : fail if any command is missing from PATH.
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { warn "missing required tool: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "install missing tools and retry"
}

# Repo root (scripts/g6e/ is two levels below root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
