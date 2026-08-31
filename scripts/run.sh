#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/dev.sh
# The daily development boot keeps the playtest HUD and F1/F2 binds; a bare
# `love app/` run is product mode.
exec love app/ --dev "$@"
