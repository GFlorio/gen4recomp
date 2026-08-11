#!/usr/bin/env bash
# The single test command. Runs every available layer:
#   scripts/test.sh
#   scripts/test.sh --list
#   scripts/test.sh --layer unit|component|graphics|rom|acceptance
#   scripts/test.sh --filter <substring-or-pattern>
#   scripts/test.sh --rom-source <path-to.nds-or.zip>
#
# Arguments are parsed by tests/runner/Cli.lua; this script only decides where
# the save root lives and whether to prepare the derived cache first. With a
# ready dump the published derived cache is checked before the ROM-gated layers. The
# incremental builder runs only when that audit finds no usable cache; with no
# dump those layers skip loudly.
# G4RECOMP_REQUIRE_ROM_TESTS=1 makes a missing dump fatal.
# Exit status: 0 green, 1 failures or a missing required capability, 2 usage.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

# Match the development container's supported graphics host. Callers may still
# override either variable for driver diagnosis, but the default test command
# must create the same offscreen software context on a machine without a
# desktop session.
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-offscreen}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# The graphics layer is part of the required surface, so a whole-run selection
# that executes no graphics test fails instead of passing silently. Callers
# may still override it for diagnosis, like the SDL variables above.
export G4RECOMP_REQUIRE_GRAPHICS_TESTS="${G4RECOMP_REQUIRE_GRAPHICS_TESTS:-1}"

# `love romdump/ --build-cache` exits 2 with "no ready dump" when there is
# nothing to prepare; any other nonzero status is a real preparation failure.
NO_DUMP_STATUS=2
BUILD_LOG=.agents/tmp/buildcache.log

# Preparation exists for the ROM-gated layers: listing executes nothing, and the
# three ROM-independent layers never need the derived cache. A supplied source is
# always imported, whatever layer it is paired with.
rom_source=""
listing=0
rom_independent=0
args=("$@")
index=0
while [ "$index" -lt "${#args[@]}" ]; do
  case "${args[$index]}" in
    --rom-source) rom_source="${args[$((index + 1))]:-}" ;;
    --list) listing=1 ;;
    --layer)
      case "${args[$((index + 1))]:-}" in
        unit | component | graphics) rom_independent=1 ;;
      esac
      ;;
  esac
  index=$((index + 1))
done

prepare=1
if [ "$listing" -eq 1 ] || { [ "$rom_independent" -eq 1 ] && [ -z "$rom_source" ]; }; then
  prepare=0
fi

status=0
if [ "$prepare" -eq 1 ]; then
  # Reject bad arguments before paying for a cache build or a ROM import: the
  # discovery-only pass runs the same parser and exits 2 on a usage error. When
  # nothing expensive follows, the run itself reports the usage error.
  love game/ --test --list "$@" >/dev/null

  if [ -n "$rom_source" ]; then
    # An isolated save root: importing and building a supplied source must never
    # touch the user's ordinary cache or saves.
    isolated="$(mktemp -d)"
    trap 'rm -rf "$isolated"' EXIT
    export XDG_DATA_HOME="$isolated"
    echo "== import and build $rom_source into $isolated =="
    love romdump/ --build-cache "$rom_source"
  else
    mkdir -p "$(dirname "$BUILD_LOG")"
    # CacheBuilder owns the complete dependency identity for every derived
    # artifact. Running it is cheap when current and prevents tests from
    # accepting a merely complete but stale cache.
    echo "== prepare derived cache (log: $BUILD_LOG) =="
    love romdump/ --build-cache >"$BUILD_LOG" 2>&1 || status=$?
    if [ "$status" -ne 0 ] && [ "$status" -ne "$NO_DUMP_STATUS" ]; then
      tail -n 20 "$BUILD_LOG" >&2
      echo "test: derived-cache preparation failed (exit $status); see $BUILD_LOG" >&2
      exit "$status"
    fi
    { grep -v ' current$' "$BUILD_LOG" | tail -n 5; } || true
  fi

  if [ "$status" -eq 0 ]; then
    export G4RECOMP_DERIVED_CACHE_READY=1
  fi
fi

# Not `exec`: the isolated save root of --rom-source is removed by the EXIT trap,
# which a replaced process would never run.
status=0
love game/ --test "$@" || status=$?
exit "$status"
