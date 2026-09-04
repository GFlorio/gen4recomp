#!/usr/bin/env python3
"""Classify tracked Lua paths used by repository CI tooling."""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys


SCOPES = (
    "production",
    "test",
    "reference",
    "generated",
    "ignored",
    "tooling",
    "type",
    "vendor",
)
FIRST_PARTY_SCOPES = {"production", "test", "reference", "tooling"}


def _normalize(path: str) -> str:
    normalized = path.replace("\\", "/")
    parts = normalized.split("/")
    if (
        not normalized
        or normalized.startswith("/")
        or (len(normalized) >= 2 and normalized[1] == ":")
        or ".." in parts
        or any(not part for part in parts)
        or not normalized.endswith(".lua")
    ):
        raise ValueError(f"non-portable Lua path: {path!r}")
    return normalized


def classify(path: str) -> str:
    """Return the sole source category for a repository-relative Lua path."""
    normalized = _normalize(path)
    parts = normalized.split("/")
    root = parts[0]

    if "tests" in parts:
        return "test"
    if root == "vendor":
        return "vendor"
    if root == "types":
        return "type"
    if root == "site" or normalized.startswith("data/generated/"):
        return "generated"
    if root in {".agents", ".cache", ".claude", "import-output", "log", "tmp"}:
        return "ignored"
    if root in {"scripts", "tools", ".github"}:
        return "tooling"
    if root == "data":
        return "reference"
    if root in {"app", "game", "gen4", "libs", "romdump"}:
        return "production"
    raise ValueError(f"unclassified tracked Lua path: {normalized}")


def tracked_paths(repository_root: Path) -> list[str]:
    """Return all tracked Lua paths, rejecting a path the taxonomy cannot classify."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), "ls-files", "--", "*.lua"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot enumerate tracked Lua paths: {error}") from error
    paths = []
    for line in result.stdout.splitlines():
        normalized = _normalize(line)
        classify(normalized)
        paths.append(normalized)
    return sorted(paths)


def paths_for_scope(repository_root: Path, scope: str) -> list[str]:
    if scope not in (*SCOPES, "first-party", "all"):
        raise ValueError(f"unknown source scope: {scope!r}")
    paths = tracked_paths(repository_root)
    if scope == "all":
        return paths
    if scope == "first-party":
        return [path for path in paths if classify(path) in FIRST_PARTY_SCOPES]
    return [path for path in paths if classify(path) == scope]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--repository-root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    try:
        paths = paths_for_scope(args.repository_root.resolve(), args.scope)
        if not paths:
            raise ValueError(f"source scope {args.scope!r} is empty")
    except ValueError as error:
        print(f"source scope: {error}", file=sys.stderr)
        return 1
    print("\n".join(paths))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
