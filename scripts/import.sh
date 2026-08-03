#!/usr/bin/env bash
# Headless ROM import. Usage: scripts/import.sh <path-to.nds>
# The version (HeartGold/SoulSilver) is detected from the ROM's SHA-1. Validates
# and dumps the ROM into the private cache, exit 0 on success. Runs windowless
# (see conf.lua).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

ROM="${1:?usage: import.sh <path-to.nds>}"

exec love . --import-rom "$ROM" --import-only
