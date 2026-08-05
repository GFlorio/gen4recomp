#!/usr/bin/env bash
# Inventory the SBC transform features (scaling rules, billboards, NODEMIX,
# CALLDL) used by every terrain and building model in the dump.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
exec love romdump/ --inspect-sbc
