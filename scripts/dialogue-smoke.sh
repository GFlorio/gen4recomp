#!/usr/bin/env bash
# Dialogue render smoke: boots the field runtime with the developer dialogue
# opened programmatically, drives it through reveal/boundary/advance/close with
# Action, and captures one frame per aspect ratio to the private cache. Needs a
# display (LÖVE OpenGL). Usage:
#   scripts/dialogue-smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

run_aspect() {
  local width="$1" height="$2" name="$3"
  echo "dialogue-smoke: ${width}x${height} ($name)"
  G4RECOMP_WINDOW_WIDTH="$width" G4RECOMP_WINDOW_HEIGHT="$height" \
    G4RECOMP_DIALOGUE_SMOKE=1 \
    G4RECOMP_SHOT="dialogue-smoke-$name.png" \
    love game/ --field
}

run_aspect 960 720 "43"
run_aspect 1280 720 "169"
run_aspect 1920 720 "ultrawide"

echo "screenshots: $G4RECOMP_SAVE_DIR/love/g4recomp/dialogue-smoke-*.png"
