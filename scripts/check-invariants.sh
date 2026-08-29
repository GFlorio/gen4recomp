#!/usr/bin/env bash
# Repository content invariants: the compiler/renderer core must stay
# target-agnostic, and the game and runtime library sources must never write
# to the terminal. lint.sh is the single static gate. Default scope is
# git-tracked Lua sources and the fixed core-module list; explicit path
# arguments run both rule sets over the given files (self-test hook, so a
# planted violation is demonstrable without touching tracked files).
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
violation() {
  echo "invariants: $1" >&2
  fail=1
}

# Pre-existing stored anonymous behavior pending conversion to named functions.
# These exact paths are temporary migration exemptions, not a source-policy API.
stored_anonymous_migration_exemptions=(
  "game/src/game/App.lua"
  "game/src/game/FieldState.lua"
  "libs/assets/src/Utf8Glyphs.lua"
  "libs/codec/src/LuaWriter.lua"
  "libs/engine/src/FieldCoverage.lua"
  "libs/engine/src/FieldDialogueController.lua"
  "libs/engine/src/FieldDialogueTheme.lua"
  "libs/engine/src/FieldEventState.lua"
  "libs/engine/src/FieldMapLoader.lua"
  "libs/engine/src/FieldTerrainEffectModelFactory.lua"
  "libs/engine/src/FieldTerrainEffectRenderer.lua"
  "libs/engine/src/NitroPoseBackend.lua"
  "libs/engine/src/audio/SequencePlayer.lua"
  "libs/engine/src/script/ScriptDialogueHost.lua"
  "libs/engine/src/script/ScriptLoader.lua"
  "libs/errors/src/Errors.lua"
  "romdump/src/ProducerFingerprint.lua"
  "romdump/src/digest/FieldCellCacheWriter.lua"
  "romdump/src/digest/MapCatalog.lua"
  "romdump/src/digest/NsbmdStaticTransforms.lua"
  "romdump/src/digest/SbcInventory.lua"
  "romdump/src/digest/WorldManifest.lua"
  "romdump/src/digest/nitro/GxDisplayList.lua"
  "romdump/src/digest/nitro/Nsbmd.lua"
  "romdump/src/digest/nitro/TextureDecoder.lua"
  "romdump/src/digest/script/MovementDecoder.lua"
  "romdump/src/digest/script/ScriptCompiler.lua"
  "romdump/src/digest/script/SourceCatalog.lua"
  "romdump/src/digest/script/Structurer.lua"
)

is_stored_anonymous_migration_exempt() {
  local path="$1"
  local exempt_path
  for exempt_path in "${stored_anonymous_migration_exemptions[@]}"; do
    [ "$path" = "$exempt_path" ] && return 0
  done
  return 1
}

check_stored_anonymous_behavior_file() {
  local path="$1"
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*-- ]] && continue
    if [[ "$line" =~ =\ function\( ]] || [[ "$line" =~ return\ function\( ]]; then
      return 0
    fi
  done < "$path"
  return 1
}

# Check A — target-specific branches in the core. A missing module is a
# violation: the gate must not silently skip a core file.
check_forbidden_phrases() {
  local path="$1"
  local phrases=(MAP_NEW_BARK ELMS_LAB area00light area01light "lightTypeRaw ==")
  local p
  for p in "${phrases[@]}"; do
    if grep -Fq "$p" "$path"; then
      violation "$path contains target-specific phrase: $p"
    fi
  done
}

check_target_specific() {
  local modules=(
    "romdump/src/digest/nitro/Nsbmd.lua"
    "romdump/src/digest/MaterialCompiler.lua"
    "romdump/src/digest/MeshCompiler.lua"
    "libs/engine/src/MapRenderer.lua"
    "libs/engine/src/shaders/map.glsl"
  )
  local m
  for m in "${modules[@]}"; do
    if [ ! -r "$m" ]; then
      violation "core module missing or unreadable: $m"
      continue
    fi
    check_forbidden_phrases "$m"
  done
}

# Check B — terminal output from game/runtime source. The bare-print rule
# mirrors the Lua contract: `print(` not preceded by an identifier character,
# '_', '.', or ':' (line-start counts as unpreceded; a line-based grep is
# exactly equivalent to the whole-file pattern).
check_terminal_output_file() {
  local path="$1"
  if grep -Fq "io.stderr" "$path"; then
    violation "$path must not write to stderr"
  fi
  if grep -Fq "io.stdout" "$path"; then
    violation "$path must not write to stdout"
  fi
  if grep -Eq '(^|[^A-Za-z0-9_.:])print\(' "$path"; then
    violation "$path must not call global print"
  fi
}

check_tracked_scope() {
  local tracked
  tracked="$(git ls-files 2>/dev/null)" || return 0
  [ -n "$tracked" ] || return 0
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^game/src/.*\.lua$ ]] || [[ "$line" =~ ^libs/[^/]+/src/.*\.lua$ ]] || [[ "$line" =~ ^romdump/src/.*\.lua$ ]]; then
      # A tracked file deleted from the working tree (a pending deletion)
      # has no source content to scan.
      [ -r "$line" ] || continue
      if [[ "$line" =~ ^game/src/.*\.lua$ ]] || [[ "$line" =~ ^libs/[^/]+/src/.*\.lua$ ]]; then
        check_terminal_output_file "$line"
      fi
      if check_stored_anonymous_behavior_file "$line" && ! is_stored_anonymous_migration_exempt "$line"; then
        violation "$line contains stored anonymous behavior; name the function"
      fi
    fi
  done <<< "$tracked"
}

check_stored_anonymous_migration_exemptions() {
  local path
  for path in "${stored_anonymous_migration_exemptions[@]}"; do
    if [ ! -r "$path" ] || ! check_stored_anonymous_behavior_file "$path"; then
      violation "stale stored-anonymous migration exemption: $path"
    fi
  done
}

check_target_specific

if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    [ -r "$path" ] || { violation "cannot read: $path"; continue; }
    check_forbidden_phrases "$path"
    check_terminal_output_file "$path"
    if check_stored_anonymous_behavior_file "$path"; then
      violation "$path contains stored anonymous behavior; name the function"
    fi
  done
else
  check_tracked_scope
  check_stored_anonymous_migration_exemptions
fi

exit "$fail"
