#!/usr/bin/env bash
# Regenerates docs/script-api-v1.md from libs/engine/src/script/Schema.lua.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
exec love tools/gen-script-docs/
