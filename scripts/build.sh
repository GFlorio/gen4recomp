#!/usr/bin/env bash
# Compile every catalog map into the private derived cache for every ready dump
# and write the world manifest. Needs a ready imported dump.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
exec love romdump/ --build
