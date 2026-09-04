#!/usr/bin/env python3
"""Contract tests for structural hotspot ceilings and baseline validation."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER_PATH = Path(__file__).with_name("check_structure_budget.py")


def baseline() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "thresholds": {
            "maxCcn": 25,
            "maxNloc": 100,
            "maxPhysicalLines": 1200,
            "maxDirectProductionFiles": 40,
        },
        "files": {
            "libs/legacy/Schema.lua": {
                "classification": "retained-schema-catalog",
                "rationale": "cohesive schema owner",
                "maxCcn": 28,
                "maxNloc": 132,
                "physicalLines": 1500,
            }
        },
        "directories": {
            "libs/legacy": {
                "classification": "refactor",
                "rationale": "mixed-responsibility directory awaiting ownership split",
                "directProductionFiles": 41,
            }
        },
    }


def report(
    *,
    ccn: int = 28,
    nloc: int = 132,
    physical_lines: int = 1500,
    direct_files: int = 41,
    file_path: str = "libs/legacy/Schema.lua",
    directory_path: str = "libs/legacy",
) -> dict[str, object]:
    return {
        "schemaVersion": 4,
        "source": {
            "files": [
                {
                    "path": file_path,
                    "bytes": 9000,
                    "physicalLines": physical_lines,
                }
            ]
        },
        "directories": {
            "files": [
                {"path": directory_path, "directProductionFiles": direct_files}
            ]
        },
        "structure": {
            "files": [
                {
                    "path": file_path,
                    "maxCcn": ccn,
                    "maxNloc": nloc,
                }
            ]
        },
    }


class StructureBudgetTest(unittest.TestCase):
    """Protect fail-closed comparison of generated structure and checked-in ceilings."""

    def run_checker(self, current: dict[str, object], pinned: dict[str, object]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path = root / "quality-report.json"
            baseline_path = root / "structure-baseline.json"
            report_path.write_text(json.dumps(current), encoding="utf-8")
            baseline_path.write_text(json.dumps(pinned), encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(CHECKER_PATH),
                    "--report",
                    str(report_path),
                    "--baseline",
                    str(baseline_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_unchanged_grandfathered_ceiling_passes(self) -> None:
        result = self.run_checker(report(), baseline())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_growth_of_one_metric_fails_with_path_and_metric(self) -> None:
        result = self.run_checker(report(ccn=29), baseline())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libs/legacy/Schema.lua", result.stderr + result.stdout)
        self.assertIn("CCN", (result.stderr + result.stdout).upper())

    def test_new_unclassified_file_or_directory_fails(self) -> None:
        current = report()
        current["source"] = {
            "files": [
                {
                    "path": "game/new/Hotspot.lua",
                    "bytes": 1000,
                    "physicalLines": 1201,
                }
            ]
        }
        current["directories"] = {
            "files": [{"path": "game/new", "directProductionFiles": 41}]
        }
        result = self.run_checker(current, baseline())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("game/new", result.stderr + result.stdout)

    def test_missing_baseline_file_requires_explicit_deletion(self) -> None:
        pinned = baseline()
        current = report()
        current["source"] = {"files": []}
        current["structure"] = {"files": []}
        result = self.run_checker(current, pinned)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Schema.lua", result.stderr + result.stdout)

        pinned["files"]["libs/legacy/Schema.lua"]["deleted"] = True  # type: ignore[index]
        result = self.run_checker(current, pinned)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_moved_baseline_entry_keeps_its_numeric_ceiling(self) -> None:
        pinned = baseline()
        file_entry = pinned["files"].pop("libs/legacy/Schema.lua")  # type: ignore[union-attr]
        directory_entry = pinned["directories"].pop("libs/legacy")  # type: ignore[union-attr]
        pinned["files"]["libs/moved/Schema.lua"] = file_entry  # type: ignore[index]
        pinned["directories"]["libs/moved"] = directory_entry  # type: ignore[index]
        result = self.run_checker(
            report(file_path="libs/moved/Schema.lua", directory_path="libs/moved"),
            pinned,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_schema_and_duplicate_baseline_entries_fail_closed(self) -> None:
        malformed = baseline()
        malformed["schemaVersion"] = 4
        result = self.run_checker(report(), malformed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("schema", (result.stderr + result.stdout).lower())

        duplicate = baseline()
        duplicate["files"] = [
            {"path": "libs/legacy/Schema.lua", "classification": "refactor"},
            {"path": "libs/legacy/Schema.lua", "classification": "refactor"},
        ]
        result = self.run_checker(report(), duplicate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate", (result.stderr + result.stdout).lower())


if __name__ == "__main__":
    unittest.main()
