#!/usr/bin/env bash
# Compile a target map into the private derived cache for every ready dump.
# Needs an imported dump (run scripts/integration.sh or an import first).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
exec love romdump/ --build-map "${1:?usage: build-map.sh <MAP_ID_OR_SYMBOL>}"
