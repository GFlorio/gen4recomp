#!/usr/bin/env bash
# Rebuild the complete game-facing cache. Reuses an existing raw dump; when no
# dump is ready, accepts a ROM path, imports it, then builds the derived cache.
# Pass --forcedump with a ROM to replace an existing raw dump before rebuilding.
# Exits nonzero when any resolved map failed asset compilation; pass
# --allow-compile-exclusions for an exploratory run that accepts them.
# Usage: scripts/buildcache.sh [path-to.nds-or.zip] [--allow-compile-exclusions]
#        scripts/buildcache.sh --forcedump <path-to.nds-or.zip>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

flags=()
args=()
for a in "$@"; do
  if [ "$a" = "--allow-compile-exclusions" ]; then flags+=("$a"); else args+=("$a"); fi
done

if [ "${args[0]:-}" = "--forcedump" ]; then
  if [ "${#args[@]}" -ne 2 ]; then
    echo "usage: scripts/buildcache.sh --forcedump <path-to.nds-or.zip>" >&2
    exit 2
  fi
  exec love romdump/ --build-cache --forcedump "${args[1]}" ${flags[@]+"${flags[@]}"}
fi

if [ "${#args[@]}" -gt 1 ]; then
  echo "usage: scripts/buildcache.sh [path-to.nds-or.zip] [--allow-compile-exclusions]" >&2
  exit 2
fi

exec love romdump/ --build-cache ${args[@]+"${args[@]}"} ${flags[@]+"${flags[@]}"}
