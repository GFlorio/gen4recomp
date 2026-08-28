#!/usr/bin/env python3
"""Normalize analyzer reports and render the static code-health summary."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import html
import json
import math
from pathlib import Path
import statistics
import subprocess
from typing import Any


EXCLUDED_PREFIXES = [
    "tests/",
    "**/tests/",
    "vendor/",
    "types/",
    "tools/",
    "scripts/",
    "site/",
    ".github/",
    "data/generated/",
    "data/scripts/overrides/",
]
STRUCTURAL_ROOT_EXCLUSIONS = {
    ".agents",
    ".cache",
    ".claude",
    ".github",
    "import-output",
    "log",
    "scripts",
    "site",
    "tmp",
    "tools",
    "types",
    "vendor",
}


def _load_json_value(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as report_file:
            return json.load(report_file)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read valid JSON from {path}: {error}") from error


def _load_json(path: Path) -> dict[str, Any]:
    value = _load_json_value(path)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def _parse_luals_report(path: Path) -> dict[str, Any]:
    report = _load_json_value(path)
    if report == []:
        return {
            "total": 0,
            "files": 0,
            "bySeverity": {"error": 0, "warning": 0, "information": 0, "hint": 0},
        }
    if not isinstance(report, dict):
        raise ValueError(f"LuaLS report {path} must contain a JSON object or empty array")
    by_severity = {"error": 0, "warning": 0, "information": 0, "hint": 0}
    total = 0
    diagnostic_files: set[str] = set()
    severity_names = {1: "error", 2: "warning", 3: "information", 4: "hint"}
    for file_name, diagnostics in report.items():
        if not isinstance(file_name, str) or not file_name:
            raise ValueError(f"LuaLS report {path} contains an invalid file name")
        if not isinstance(diagnostics, list):
            raise ValueError(f"LuaLS report {path} contains a file with non-array diagnostics")
        if diagnostics:
            diagnostic_files.add(file_name)
        for diagnostic in diagnostics:
            if not isinstance(diagnostic, dict):
                raise ValueError(f"LuaLS report {path} contains a non-object diagnostic")
            severity = diagnostic.get("severity")
            if isinstance(severity, bool) or severity not in severity_names:
                raise ValueError(f"LuaLS report {path} contains unsupported severity {severity!r}")
            by_severity[severity_names[severity]] += 1
            total += 1
    return {"total": total, "files": len(diagnostic_files), "bySeverity": by_severity}


def _number(value: Any, path: Path, field: str) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        raise ValueError(f"{path} has a non-numeric {field}")
    try:
        parsed = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{path} has a non-numeric {field}") from error
    if not math.isfinite(parsed):
        raise ValueError(f"{path} has a non-finite {field}")
    if parsed.is_integer():
        return int(parsed)
    return parsed


def _nearest_rank(values: list[int | float], percentile: float) -> int | float:
    if not values:
        raise ValueError("nearest-rank requires at least one value")
    rank = max(1, min(len(values), math.ceil(percentile * len(values))))
    return sorted(values)[rank - 1]


def _parse_lizard_report(path: Path) -> dict[str, Any]:
    try:
        with path.open(newline="", encoding="utf-8") as report_file:
            reader = csv.DictReader(report_file)
            if reader.fieldnames is None or "NLOC" not in reader.fieldnames or "CCN" not in reader.fieldnames:
                raise ValueError(f"Lizard report {path} must have NLOC and CCN headers")
            nloc_values: list[int | float] = []
            ccn_values: list[int | float] = []
            for row in reader:
                if not row or any(value is None or value.strip() == "" for value in row.values()):
                    raise ValueError(f"Lizard report {path} contains an empty row")
                nloc_values.append(_number(row["NLOC"], path, "NLOC"))
                ccn_values.append(_number(row["CCN"], path, "CCN"))
    except OSError as error:
        raise ValueError(f"cannot read Lizard report {path}: {error}") from error
    if not nloc_values:
        raise ValueError(f"Lizard report {path} contains no function rows")
    return {
        "functions": len(nloc_values),
        "ccn": {
            "median": statistics.median(ccn_values),
            "p90": _nearest_rank(ccn_values, 0.90),
            "p95": _nearest_rank(ccn_values, 0.95),
            "p99": _nearest_rank(ccn_values, 0.99),
            "max": max(ccn_values),
        },
        "nloc": {
            "median": statistics.median(nloc_values),
            "p95": _nearest_rank(nloc_values, 0.95),
            "max": max(nloc_values),
        },
    }


def _parse_jscpd_report(path: Path) -> dict[str, Any]:
    report = _load_json(path)
    statistics = report.get("statistics")
    if not isinstance(statistics, dict) or not isinstance(statistics.get("total"), dict):
        raise ValueError(f"jscpd report {path} must contain statistics.total")
    total = statistics["total"]
    fields = ("sources", "clones", "duplicatedLines", "percentage")
    if any(field not in total for field in fields):
        raise ValueError(f"jscpd report {path} statistics.total is missing a required field")
    return {
        "sources": _number(total["sources"], path, "statistics.total.sources"),
        "clones": _number(total["clones"], path, "statistics.total.clones"),
        "duplicatedLines": _number(total["duplicatedLines"], path, "statistics.total.duplicatedLines"),
        "percentage": _number(total["percentage"], path, "statistics.total.percentage"),
    }


def _is_excluded_source(source_file: str) -> bool:
    parts = source_file.split("/")
    if "tests" in parts or parts[0] in STRUCTURAL_ROOT_EXCLUSIONS:
        return True
    return source_file.startswith("data/generated/") or source_file.startswith("data/scripts/overrides/")


def _normalize_source_file(source_file: Any, path: Path) -> str:
    if not isinstance(source_file, str) or not source_file:
        raise ValueError(f"Graphify report {path} contains an invalid source_file")
    normalized = source_file.replace("\\", "/")
    parts = normalized.split("/")
    if (
        normalized.startswith("/")
        or (len(normalized) >= 2 and normalized[1] == ":")
        or ".." in parts
        or any(not part for part in parts)
    ):
        raise ValueError(f"Graphify report {path} contains a non-portable source_file {source_file!r}")
    if not normalized.endswith(".lua"):
        raise ValueError(f"Graphify report {path} contains a non-Lua source_file {source_file!r}")
    if _is_excluded_source(normalized):
        raise ValueError(f"Graphify report {path} contains an excluded source_file {source_file!r}")
    return normalized


def _import_cycle_groups(adjacency: dict[Any, set[Any]]) -> int:
    nodes = set(adjacency)
    for targets in adjacency.values():
        nodes.update(targets)
    forward = {node: set(adjacency.get(node, set())) for node in nodes}
    reverse = {node: set() for node in nodes}
    for source, targets in forward.items():
        for target in targets:
            reverse[target].add(source)

    visited: set[Any] = set()
    finish_order: list[Any] = []
    for start in nodes:
        if start in visited:
            continue
        stack = [(start, False)]
        while stack:
            node, expanded = stack.pop()
            if expanded:
                finish_order.append(node)
                continue
            if node in visited:
                continue
            visited.add(node)
            stack.append((node, True))
            for target in forward[node]:
                if target not in visited:
                    stack.append((target, False))

    visited.clear()
    cycles = 0
    for start in reversed(finish_order):
        if start in visited:
            continue
        component: set[Any] = set()
        stack = [start]
        visited.add(start)
        while stack:
            node = stack.pop()
            component.add(node)
            for source in reverse[node]:
                if source not in visited:
                    visited.add(source)
                    stack.append(source)
        if len(component) > 1 or any(node in forward[node] for node in component):
            cycles += 1
    return cycles


def _parse_graphify_report(path: Path) -> dict[str, Any]:
    report = _load_json(path)
    if report.get("directed") is not True:
        raise ValueError(f"Graphify report {path} must be directed")
    nodes = report.get("nodes")
    links = report.get("links")
    if not isinstance(nodes, list) or not nodes:
        raise ValueError(f"Graphify report {path} must contain nonempty nodes")
    if not isinstance(links, list) or not links:
        raise ValueError(f"Graphify report {path} must contain nonempty links")

    node_sources: dict[Any, str] = {}
    node_ids: set[Any] = set()
    communities: set[Any] = set()
    modules: set[str] = set()
    for node in nodes:
        if not isinstance(node, dict) or "id" not in node:
            raise ValueError(f"Graphify report {path} contains an invalid node")
        node_id = node["id"]
        try:
            hash(node_id)
        except TypeError as error:
            raise ValueError(f"Graphify report {path} contains an unhashable node id") from error
        if node_id in node_ids:
            raise ValueError(f"Graphify report {path} contains a duplicate node id {node_id!r}")
        node_ids.add(node_id)
        source_file = node.get("source_file")
        if "source_file" in node and source_file is not None:
            normalized = _normalize_source_file(source_file, path)
            node_sources[node_id] = normalized
            modules.add(normalized)
            if node.get("community") is not None:
                try:
                    communities.add(node["community"])
                except TypeError as error:
                    raise ValueError(f"Graphify report {path} contains an unhashable community") from error

    provenance = {"extracted": 0, "inferred": 0, "ambiguous": 0}
    import_pairs: set[tuple[str, str]] = set()
    adjacency = {module: set() for module in modules}
    for link in links:
        if not isinstance(link, dict):
            raise ValueError(f"Graphify report {path} contains an invalid link")
        if any(field not in link for field in ("source", "target", "relation", "confidence")):
            raise ValueError(f"Graphify report {path} contains a link missing a required field")
        for endpoint in ("source", "target"):
            endpoint_id = link[endpoint]
            try:
                hash(endpoint_id)
            except TypeError as error:
                raise ValueError(f"Graphify report {path} contains an unhashable link {endpoint}") from error
            if endpoint_id not in node_ids:
                raise ValueError(f"Graphify report {path} contains a link to an unknown node {endpoint_id!r}")
        if "source_file" in link and link["source_file"] is not None:
            _normalize_source_file(link["source_file"], path)
        confidence = link.get("confidence")
        if not isinstance(confidence, str) or confidence.upper() not in {"EXTRACTED", "INFERRED", "AMBIGUOUS"}:
            raise ValueError(f"Graphify report {path} contains unsupported link confidence {confidence!r}")
        provenance[confidence.lower()] += 1
        if link.get("relation") == "imports":
            source = node_sources.get(link.get("source"))
            target = node_sources.get(link.get("target"))
            if source is not None and target is not None:
                import_pairs.add((source, target))
                adjacency[source].add(target)

    return {
        "modules": len(modules),
        "nodes": len(nodes),
        "edges": len(links),
        "communities": len(communities),
        "importEdges": len(import_pairs),
        "importCycleGroups": _import_cycle_groups(adjacency),
        "provenance": provenance,
    }


def _version(command: str) -> str:
    try:
        result = subprocess.run([command, "--version"], check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot read {command} version: {error}") from error
    version = (result.stdout or result.stderr).strip()
    if not version:
        raise ValueError(f"{command} returned an empty version")
    return version


def _git_commit(repository_root: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot determine analyzed git commit: {error}") from error
    commit = result.stdout.strip()
    if len(commit) != 40:
        raise ValueError(f"git returned an invalid commit {commit!r}")
    return commit


def _render_summary(model: dict[str, Any]) -> str:
    def value(item: Any) -> str:
        return html.escape(str(item))

    tools = model["tools"]
    diagnostics = model["diagnostics"]
    complexity = model["complexity"]
    duplication = model["duplication"]
    architecture = model["architecture"]
    cards = (
        ("LuaLS diagnostics", diagnostics["total"]),
        ("Functions", complexity["functions"]),
        ("Duplicated lines", duplication["duplicatedLines"]),
        ("Architecture modules", architecture["modules"]),
    )
    card_markup = "\n".join(
        f'        <article class="card"><h3>{html.escape(title)}</h3><p>{value(metric)}</p></article>'
        for title, metric in cards
    )
    human_reports = (
        ("Lizard HTML", "reports/lizard/index.html"),
        ("jscpd HTML", "reports/jscpd/jscpd-report.html"),
        ("Graphify graph", "reports/graphify/graph.html"),
        ("Graphify call flow", "reports/graphify/callflow.html"),
        ("jscpd Markdown", "reports/jscpd/jscpd-report.md"),
    )
    machine_reports = (
        ("Normalized quality report", "quality-report.json"),
        ("LuaLS diagnostics", "reports/luals/check.json"),
        ("Lizard functions", "reports/lizard/functions.csv"),
        ("jscpd report", "reports/jscpd/jscpd-report.json"),
        ("Graphify graph", "reports/graphify/graph.json"),
    )
    human_markup = "\n".join(
        f'          <li><a href="{html.escape(link, quote=True)}">{html.escape(title)}</a></li>'
        for title, link in human_reports
    )
    machine_markup = "\n".join(
        f'          <li><a href="{html.escape(link, quote=True)}" download>{html.escape(title)}</a></li>'
        for title, link in machine_reports
    )
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Code health — g4recomp</title>
    <link rel="stylesheet" href="../styles.css">
  </head>
  <body>
    <main class="page-shell">
      <section class="hero" aria-labelledby="report-title">
        <p class="eyebrow">Static analysis report</p>
        <h1 id="report-title">Code health</h1>
        <p class="lede">Generated for commit <code>{value(model["commit"])}</code> at {value(model["generatedAt"])}.</p>
        <p>LuaLS diagnostics use the whole workspace. Complexity, duplication, and architecture reports use tracked production Lua.</p>
      </section>
      <section aria-labelledby="headline-title">
        <h2 id="headline-title">Headline metrics</h2>
        <div class="grid">
{card_markup}
        </div>
      </section>
      <section class="panel" aria-labelledby="tools-title">
        <h2 id="tools-title">Analyzer versions</h2>
        <div class="table-wrap"><table>
          <tbody>
            <tr><th scope="row">LuaLS</th><td>{value(tools["luaLanguageServer"])}</td></tr>
            <tr><th scope="row">Lizard</th><td>{value(tools["lizard"])}</td></tr>
            <tr><th scope="row">jscpd</th><td>{value(tools["jscpd"])}</td></tr>
            <tr><th scope="row">Graphify</th><td>{value(tools["graphify"])}</td></tr>
          </tbody>
        </table></div>
      </section>
      <section class="panel" aria-labelledby="human-reports-title">
        <h2 id="human-reports-title">Human reports</h2>
        <ul>
{human_markup}
        </ul>
      </section>
      <section class="panel" aria-labelledby="machine-downloads-title">
        <h2 id="machine-downloads-title">Machine downloads</h2>
        <ul>
{machine_markup}
        </ul>
      </section>
      <section class="panel" aria-labelledby="architecture-note-title">
        <h2 id="architecture-note-title">Architecture interpretation</h2>
        <p>Graphify <strong>INFERRED</strong> cross-file call relationships are heuristic and must not be treated like <strong>EXTRACTED</strong> import edges.</p>
        <p>Provenance: extracted {value(architecture["provenance"]["extracted"])}, inferred {value(architecture["provenance"]["inferred"])}, ambiguous {value(architecture["provenance"]["ambiguous"])}.</p>
      </section>
    </main>
  </body>
</html>
"""


def _build_model(site_root: Path, repository_root: Path) -> dict[str, Any]:
    reports_root = site_root / "codehealth" / "reports"
    report_paths = {
        "luals": reports_root / "luals" / "check.json",
        "lizard": reports_root / "lizard" / "functions.csv",
        "jscpd": reports_root / "jscpd" / "jscpd-report.json",
        "graphify": reports_root / "graphify" / "graph.json",
    }
    model = {
        "schemaVersion": 1,
        "commit": _git_commit(repository_root),
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "tools": {
            "luaLanguageServer": _version("lua-language-server"),
            "lizard": _version("lizard"),
            "jscpd": _version("jscpd"),
            "graphify": _version("graphify"),
        },
        "scope": {
            "diagnostics": "workspace",
            "structural": "production-lua",
            "excludedPrefixes": EXCLUDED_PREFIXES,
        },
        "diagnostics": _parse_luals_report(report_paths["luals"]),
        "complexity": _parse_lizard_report(report_paths["lizard"]),
        "duplication": _parse_jscpd_report(report_paths["jscpd"]),
        "architecture": _parse_graphify_report(report_paths["graphify"]),
    }
    return model


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site-root", required=True, type=Path)
    args = parser.parse_args(argv)
    site_root = args.site_root.resolve()
    repository_root = Path(__file__).resolve().parents[1]
    try:
        model = _build_model(site_root, repository_root)
        quality_report = site_root / "codehealth" / "quality-report.json"
        summary_page = site_root / "codehealth" / "index.html"
        quality_report.write_text(json.dumps(model, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        summary_page.write_text(_render_summary(model), encoding="utf-8")
        _load_json(quality_report)
    except (OSError, ValueError) as error:
        print(f"codehealth report: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
