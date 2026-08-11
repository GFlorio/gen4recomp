#!/usr/bin/env bash
# Repository-wide policy that needs tracked-file metadata rather than Lua test
# fixtures. Commercial ROMs and derived artifacts must never enter the index.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

if git ls-files | grep -E '(^|/)(\.cache|data/generated|assets/generated|romfs|import-output)(/|$)|\.(nds|sav)$' >/dev/null; then
  echo "repository: tracked ROM payload or derived artifact" >&2
  exit 1
fi
