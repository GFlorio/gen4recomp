#!/usr/bin/env bash
# One-time developer setup. Git never installs hooks on clone (running repo code
# implicitly would be a security hole), so every contributor runs this once.
set -euo pipefail
cd "$(dirname "$0")/.."

git config core.hooksPath scripts/hooks
echo "core.hooksPath -> scripts/hooks (pre-commit runs scripts/lint.sh)"
