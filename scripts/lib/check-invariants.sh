#!/usr/bin/env bash
# Repository content invariants: the compiler/renderer core must stay
# target-agnostic, and the game and runtime library sources must never write
# to the terminal. lint.sh is the single static gate. Default scope is
# git-tracked Lua sources and the fixed core-module list; explicit path
# arguments run both rule sets over the given files (self-test hook, so a
# planted violation is demonstrable without touching tracked files).
set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0
violation() {
  echo "invariants: $1" >&2
  fail=1
}

# Targeted text check, not a Lua parser: recognizes only assigned
# `= function(` and directly returned `return function(` forms.
check_assigned_or_returned_anonymous_function_file() {
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
    "libs/nds/src/nitro/g3d/Nsbmd.lua"
    "romdump/src/digest/MaterialCompiler.lua"
    "romdump/src/digest/MeshCompiler.lua"
    "libs/nds/src/love/GxRenderer.lua"
    "libs/nds/src/love/shaders/map.glsl"
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

is_first_party_lua() {
  local path="$1"
  if [[ "$path" =~ ^app/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^game/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^gen4/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^libs/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^romdump/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^scripts/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^tests/.*\.lua$ ]]; then
    return 0
  fi
  return 1
}

check_header_diagnostic_disable_file() {
  local path="$1"
  local line
  local is_first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$is_first" -eq 1 ] && [[ "$line" =~ ^#! ]]; then
      is_first=0
      continue
    fi
    is_first=0
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*---@diagnostic[[:space:]]+disable: ]]; then
      violation "$path uses a header-wide LuaLS diagnostic disable; use source typing or a narrow line directive"
      return 0
    fi
    if [[ "$line" =~ ^[[:space:]]*-- ]]; then
      continue
    fi
    break
  done < "$path"
  return 1
}

check_tracked_scope() {
  local tracked
  tracked="$(git ls-files 2>/dev/null)" || return 0
  [ -n "$tracked" ] || return 0
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ \.lua$ ]] && is_first_party_lua "$line"; then
      [ -r "$line" ] || continue
      check_header_diagnostic_disable_file "$line" || true
    fi
    if [[ "$line" =~ ^game/src/.*\.lua$ ]] || [[ "$line" =~ ^game/hgss/src/.*\.lua$ ]] || [[ "$line" =~ ^libs/[^/]+/src/.*\.lua$ ]] || [[ "$line" =~ ^romdump/src/.*\.lua$ ]]; then
      # A tracked file deleted from the working tree (a pending deletion)
      # has no source content to scan.
      [ -r "$line" ] || continue
      if [[ "$line" =~ ^game/src/.*\.lua$ ]] || [[ "$line" =~ ^game/hgss/src/.*\.lua$ ]] || [[ "$line" =~ ^libs/[^/]+/src/.*\.lua$ ]]; then
        check_terminal_output_file "$line"
      fi
      if check_assigned_or_returned_anonymous_function_file "$line"; then
        violation "$line uses an assigned or directly returned anonymous function form; name the function"
      fi
    fi
  done <<< "$tracked"
}

check_target_specific

if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    [ -r "$path" ] || { violation "cannot read: $path"; continue; }
    check_forbidden_phrases "$path"
    check_terminal_output_file "$path"
    if check_assigned_or_returned_anonymous_function_file "$path"; then
      violation "$path uses an assigned or directly returned anonymous function form; name the function"
    fi
    if [[ "$path" =~ \.lua$ ]]; then
      check_header_diagnostic_disable_file "$path" || true
    fi
  done
else
  check_tracked_scope
fi

exit "$fail"
