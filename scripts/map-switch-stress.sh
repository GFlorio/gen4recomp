#!/usr/bin/env bash
# Switch-stress smoke: boot the 3D map diagnostic and repeatedly toggle
# between New Bark and Elm's Lab, releasing and rebuilding every GPU object each
# time. Exits nonzero if any switch fails to load. Usage:
#   scripts/map-switch-stress.sh [CYCLES]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

export G4RECOMP_SWITCH_CYCLES="${1:-8}"
exec love . --map MAP_NEW_BARK_ELMS_LAB_1F
