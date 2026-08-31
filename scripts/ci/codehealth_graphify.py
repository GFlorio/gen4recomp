#!/usr/bin/env python3
"""Build a directed Graphify report from a disposable Lua mirror."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cache-root", required=True, type=Path)
    parser.add_argument("--max-workers", required=True, type=int)
    args = parser.parse_args(argv)
    if args.max_workers < 1:
        parser.error("--max-workers must be positive")
    return args


def _resolve_paths(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    source_root = args.source_root.resolve()
    output = args.output.resolve()
    cache_root = args.cache_root.resolve()
    if not source_root.is_dir():
        raise ValueError(f"source root is not a directory: {source_root}")
    try:
        scratch_root = Path(os.path.commonpath((source_root, output.parent, cache_root)))
    except ValueError as error:
        raise ValueError("source, output, and cache paths must share a scratch root") from error
    if scratch_root == Path(scratch_root.anchor):
        raise ValueError("source, output, and cache paths must remain under a scratch root")
    return source_root, output, cache_root


def _lua_paths(source_root: Path) -> list[Path]:
    paths = sorted(path for path in source_root.rglob("*.lua") if path.is_file())
    if not paths:
        raise ValueError(f"source root contains no Lua files: {source_root}")
    return paths


def _validate_serialized_graph(output: Path) -> None:
    try:
        with output.open(encoding="utf-8") as graph_file:
            graph = json.load(graph_file)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"serialized graph is not valid JSON: {output}: {error}") from error
    if not isinstance(graph, dict) or graph.get("directed") is not True:
        raise ValueError(f"serialized Graphify graph is not directed: {output}")
    if not isinstance(graph.get("nodes"), list) or not graph["nodes"]:
        raise ValueError(f"serialized Graphify graph has no nodes: {output}")
    if not isinstance(graph.get("links"), list) or not graph["links"]:
        raise ValueError(f"serialized Graphify graph has no links: {output}")


def _build_graph(source_root: Path, output: Path, cache_root: Path, max_workers: int) -> None:
    import graphify

    paths = _lua_paths(source_root)
    extraction: dict[str, Any] = graphify.extract(
        paths,
        cache_root=cache_root,
        root=source_root,
        parallel=True,
        max_workers=max_workers,
    )
    graph = graphify.build_from_json(extraction, root=source_root, directed=True)
    if not graph.is_directed():
        raise ValueError("Graphify returned an undirected graph")
    if graph.number_of_nodes() == 0 or graph.number_of_edges() == 0:
        raise ValueError("Graphify returned an empty directed graph")
    communities = graphify.cluster(graph)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not graphify.to_json(graph, communities, str(output), force=True):
        raise ValueError(f"Graphify refused to serialize the graph: {output}")
    _validate_serialized_graph(output)


def main(argv: list[str] | None = None) -> int:
    try:
        args = _parse_args(argv)
        source_root, output, cache_root = _resolve_paths(args)
        _build_graph(source_root, output, cache_root, args.max_workers)
    except Exception as error:
        print(f"codehealth graphify: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
