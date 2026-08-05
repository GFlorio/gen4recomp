#!/usr/bin/env bash
# Derive renderability, representative cells, and land members from every ready dump.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
exec love romdump/ --analyze-maps
