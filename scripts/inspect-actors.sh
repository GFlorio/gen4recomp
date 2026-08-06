#!/usr/bin/env bash
# Compile the selected field-actor set from the private dump and print its
# structural facts. Read-only: writes no cache artifact and emits no image bytes.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
exec love romdump/ --inspect-actors
