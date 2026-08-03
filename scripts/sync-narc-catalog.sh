#!/usr/bin/env bash
# Developer-only: regenerate data/manifests/narc_catalog.lua from a local
# pret/pokeheartgold checkout (spec §11.3). Not a contributor prerequisite and
# never run at app runtime. Usage:
#   scripts/sync-narc-catalog.sh <decomp-root> <commit>
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="${1:?usage: sync-narc-catalog.sh <decomp-root> <commit>}"
COMMIT="${2:?usage: sync-narc-catalog.sh <decomp-root> <commit>}"

exec luajit tools/sync_narc_catalog.lua "$ROOT" "$COMMIT"
