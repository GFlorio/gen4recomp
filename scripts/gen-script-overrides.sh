#!/usr/bin/env bash
# Regenerate the checked-in script overrides (data/scripts/overrides/<id>.lua)
# for the New Bark slice from the first ready dump. Deterministic: identical
# dumps produce byte-identical files (the ROM conformance suite pins this).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
exec love romdump/ --gen-script-overrides
