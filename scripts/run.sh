#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
# The daily development boot keeps the playtest HUD and F1/F2 binds; a bare
# `love game/` run is product mode.
exec love game/ --dev "$@"
