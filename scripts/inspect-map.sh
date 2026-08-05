#!/usr/bin/env bash
# Inventory a target map from the private dump: field containers, map-model
# geometry, texture packs, and placed-building models. Needs a ready imported
# dump (run scripts/integration.sh first). Prints a deterministic report and
# exits nonzero if a map cannot be resolved or a required format is unsupported.
#
#   scripts/inspect-map.sh MAP_NEW_BARK_ELMS_LAB_1F
#   scripts/inspect-map.sh MAP_NEW_BARK
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

MAP="${1:-MAP_NEW_BARK_ELMS_LAB_1F}"
exec love romdump/ --inspect-map "$MAP"
