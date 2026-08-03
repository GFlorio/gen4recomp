#!/usr/bin/env bash
# Real-ROM integration test (spec §18.5). NOT run in public CI — it needs a
# legally-obtained cartridge dump. Usage:
#   scripts/integration.sh [path-to.nds]
#
# Step 1 imports the ROM headlessly; the version is detected from its SHA-1.
# Step 2 audits every ready dump in a SEPARATE process that never opens the ROM,
# proving the runtime boots from the private cache alone. Both steps run
# windowless. Any failure exits nonzero.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

ROM="${1:-tmp/rom.nds}"

if [ ! -f "$ROM" ]; then
  echo "integration: ROM not found at '$ROM'" >&2
  exit 2
fi

echo "== import (version detected from ROM) =="
love . --import-rom "$ROM" --import-only

echo
echo "== audit ready dumps without the ROM =="
love . --check-dump

echo
echo "integration: OK"
