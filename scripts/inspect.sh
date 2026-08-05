#!/usr/bin/env bash
# Inventory every renderable map from the private dump for every ready version.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
exec love romdump/ --inspect
