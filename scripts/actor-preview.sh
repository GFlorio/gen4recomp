#!/usr/bin/env bash
# Developer preview grid over the compiled field-actor visuals: every sprite,
# four directions, idle and animated walk. With an output name it captures one
# frame to the private cache and quits. Usage:
#   scripts/actor-preview.sh [out-name.png]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

if [ "$#" -ge 1 ]; then
  export G4RECOMP_SHOT="$1"
  love game/ --actors
  echo "screenshot: $G4RECOMP_SAVE_DIR/love/g4recomp/$1"
else
  exec love game/ --actors
fi
