#!/usr/bin/env python3
"""Find LuaCATS bare-table annotations and diagnostic directives."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys
from typing import Any


_ANNOTATION = re.compile(r"^\s*---@([A-Za-z][\w-]*)(?:\s+(.*))?$")
_DIRECTIVE = re.compile(r"^\s*---@diagnostic\b(.*)$")
_BARE_TABLE = re.compile(r"(?<![A-Za-z0-9_])table(?![A-Za-z0-9_<\[])")
_VALID_DIRECTIVE_STATES = {"disable", "disable-next-line", "enable", "enable-next-line"}


def _load_scope_module():
    module_path = Path(__file__).with_name("source_scope.py")
    module_spec = importlib.util.spec_from_file_location("source_scope", module_path)
    if module_spec is None or module_spec.loader is None:
        raise RuntimeError("cannot load source scope")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def _type_text(tag: str, payload: str) -> str:
    fields = payload.split(None, 1)
    if tag in {"param", "field"}:
        return fields[1] if len(fields) == 2 else ""
    if tag == "cast":
        return fields[1] if len(fields) == 2 else ""
    if tag in {"return", "type", "alias", "operator"}:
        return payload
    return ""


def _finding(path: Path, line: int, kind: str, **fields: Any) -> dict[str, Any]:
    result: dict[str, Any] = {"path": path.as_posix(), "line": line, "kind": kind}
    result.update(fields)
    return result


def _directive_finding(path: Path, line: int, payload: str) -> dict[str, Any]:
    match = re.match(r"^\s*([^:\s]+)\s*:(.*)$", payload)
    if match is None:
        return _finding(path, line, "malformed-directive")
    state, category_text = match.groups()
    category_text, separator, reason = category_text.partition("--")
    categories = [category.strip() for category in category_text.split(",") if category.strip()]
    if state not in _VALID_DIRECTIVE_STATES or not categories:
        return _finding(path, line, "malformed-directive")
    return _finding(
        path,
        line,
        "diagnostic-directive",
        state=state,
        categories=categories,
        reason=reason.strip() if separator else "",
    )


def scan_file(path: Path) -> list[dict[str, Any]]:
    """Scan one Lua file and return findings in source order."""
    findings: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise ValueError(f"cannot read Lua source {path}: {error}") from error
    for line_number, line in enumerate(lines, start=1):
        directive = _DIRECTIVE.match(line)
        if directive is not None:
            findings.append(_directive_finding(path, line_number, directive.group(1)))
            continue
        annotation = _ANNOTATION.match(line)
        if annotation is None:
            continue
        tag, payload = annotation.groups()
        if _BARE_TABLE.search(_type_text(tag, payload or "")) is not None:
            findings.append(_finding(path, line_number, "bare-table", annotation=tag, type="table"))
    return findings


def scan_paths(paths: list[Path]) -> list[dict[str, Any]]:
    findings = [finding for path in sorted(paths, key=lambda item: item.as_posix()) for finding in scan_file(path)]
    return sorted(findings, key=lambda finding: (finding["path"], finding["line"], finding["kind"]))


def _repository_paths(repository_root: Path, scope: str) -> list[Path]:
    scope_module = _load_scope_module()
    return [repository_root / path for path in scope_module.paths_for_scope(repository_root, scope)]


def _relative_findings(findings: list[dict[str, Any]], repository_root: Path) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for finding in findings:
        relative = dict(finding)
        relative["path"] = Path(finding["path"]).resolve().relative_to(repository_root).as_posix()
        normalized.append(relative)
    return normalized


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--scope", default="first-party")
    parser.add_argument("--repository-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--check", action="store_true", help="fail when findings are present")
    args = parser.parse_args(argv)
    try:
        repository_root = args.repository_root.resolve()
        findings = _relative_findings(scan_paths(_repository_paths(repository_root, args.scope)), repository_root)
        report = {"schemaVersion": 1, "scope": args.scope, "findings": findings}
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Lua policy: {error}", file=sys.stderr)
        return 1
    if args.check and findings:
        print(f"Lua policy: {len(findings)} finding(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
