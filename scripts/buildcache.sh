#!/usr/bin/env bash
# Rebuild the complete game-facing cache. Reuses an existing raw dump; when no
# dump is ready, accepts a ROM path, imports it, then builds the derived cache.
# Pass --forcedump with a ROM to replace an existing raw dump before rebuilding.
# Usage: scripts/buildcache.sh [path-to.nds-or.zip]
#        scripts/buildcache.sh --forcedump <path-to.nds-or.zip>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

if [ "${1:-}" = "--forcedump" ]; then
  if [ "$#" -ne 2 ]; then
    echo "usage: scripts/buildcache.sh --forcedump <path-to.nds-or.zip>" >&2
    exit 2
  fi
  exec love romdump/ --build-cache --forcedump "$2"
fi

if [ "$#" -gt 1 ]; then
  echo "usage: scripts/buildcache.sh [path-to.nds-or.zip]" >&2
  exit 2
fi

exec love romdump/ --build-cache "$@"
