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

echo "==> stylua --check"
stylua --check .

echo "==> lua-language-server --check"
mkdir -p .agents/tmp/luals
lua-language-server --check . --checklevel=Warning --logpath=.agents/tmp/luals
