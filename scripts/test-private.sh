#!/usr/bin/env bash
# Private target-test suite. Needs a real imported dump in the private cache
# (run scripts/integration.sh or an import first). Verifies the semantic-
# resolution and field-container target assertions for Elm's Lab and New Bark
# against every ready version.
# Runs windowless. Exits nonzero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
exec love game/ --test-private
