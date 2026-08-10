#!/usr/bin/env bash
# Static checks for the whole repo: formatting (stylua) and diagnostics
# (lua-language-server). Both analyze the full workspace — luals resolves
# `require` paths against the repo root, so a per-file mode would be unsound.
# Both exit non-zero on findings; `set -e` turns that into a failed check.
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in stylua lua-language-server; do
  command -v "$tool" >/dev/null || {
    echo "lint: $tool not found in PATH (see README 'Requirements')" >&2
    exit 1
  }
done

echo "==> temporary-spec reference guard"
# Reject references to the planning spec ("tmp/spec", "spec section N",
# "Workstream N", "milestone N", "slice N") in source, tests, data, and
# permanent docs. The patterns are narrow on purpose: bare "section"/"slice"
# and project concepts like the playable "New Bark slice" stay legal.
# lint.sh is excluded because it contains the patterns themselves.
if grep -RInE --include='*.lua' --include='*.md' --include='*.sh' --include='*.toml' \
  -e 'tmp/spec' -e 'spec section' -e 'Workstream' -e 'milestone' -e 'slice [0-9]' \
  --exclude='lint.sh' \
  README.md docs data libs game romdump tests scripts; then
  echo "lint: temporary-spec references found; replace them with durable reasoning" >&2
  exit 1
fi

echo "==> stylua --check"
stylua --check .

echo "==> lua-language-server --check"
lua-language-server --check . --checklevel=Warning --logpath=.agents/tmp/luals
