#!/usr/bin/env bash
# Convenience wrapper for a full source-ROM run: imports the given cartridge
# dump and builds its derived cache in an isolated save root, then runs the
# whole suite against it. It owns no test suite of its own — `scripts/test.sh`
# is the single test command.
#   scripts/integration.sh [path-to.nds-or.zip]
set -euo pipefail
cd "$(dirname "$0")/.."

# An unreadable path is rejected by the test command itself, with exit 2.
exec scripts/test.sh --rom-source "${1:-tmp/rom.zip}"
