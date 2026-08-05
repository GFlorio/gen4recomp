#!/usr/bin/env bash
# Render smoke: boot the 3D map diagnostic, capture one frame to the private
# cache, and quit. Prints the absolute screenshot path. Usage:
#   scripts/map-shot.sh [MAP_SYMBOL] [out-name.png]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

MAP="${1:-MAP_NEW_BARK_ELMS_LAB_1F}"
OUT="${2:-map-shot.png}"

export G4RECOMP_SHOT="$OUT"
love game/ --map "$MAP"

echo "screenshot: $G4RECOMP_SAVE_DIR/love/g4recomp/$OUT"
