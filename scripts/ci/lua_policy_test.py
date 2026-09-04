#!/usr/bin/env python3
"""Contract tests for targeted LuaCATS annotation and directive scanning."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("lua_policy.py")


def load_policy_module():
    if not MODULE_PATH.is_file():
        raise AssertionError(
            "Lua policy scanning must report annotation debt before these contract tests can pass"
        )
    module_spec = importlib.util.spec_from_file_location("lua_policy", MODULE_PATH)
    if module_spec is None or module_spec.loader is None:
        raise AssertionError("Lua policy module cannot be loaded")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


POLICY = load_policy_module()


class LuaPolicyTest(unittest.TestCase):
    """Protect semantic type-expression and diagnostic-directive findings."""

    def test_scan_reports_bare_types_and_directives_but_not_shaped_types(self) -> None:
        source = """\
---@param bare table
---@return table?
---@param mapping table<string, string>
---@param array string[]
---@param record {name: string}
---@param optional NamedType?
---@diagnostic disable-next-line: undefined-field, need-check-nil -- fixture reason
local function read(value)
  if type(value) == "table" then
    return value
  end
  return nil
end
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text(source, encoding="utf-8")
            findings = POLICY.scan_file(path)

        bare = [finding for finding in findings if finding["kind"] == "bare-table"]
        directives = [finding for finding in findings if finding["kind"] == "diagnostic-directive"]
        self.assertEqual([(finding["line"], finding["kind"]) for finding in bare], [(1, "bare-table"), (2, "bare-table")])
        self.assertEqual(len(directives), 1)
        self.assertEqual(directives[0]["line"], 7)
        self.assertEqual(directives[0]["state"], "disable-next-line")
        self.assertEqual(directives[0]["categories"], ["undefined-field", "need-check-nil"])
        self.assertIn("fixture reason", directives[0]["reason"])
        self.assertNotIn("mapping", " ".join(str(finding) for finding in findings))
        self.assertNotIn("array", " ".join(str(finding) for finding in findings))
        self.assertNotIn("record", " ".join(str(finding) for finding in findings))

    def test_findings_are_stable_and_include_normalized_source_fields(self) -> None:
        source = "---@return table\n---@diagnostic disable: undefined-global -- reason\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text(source, encoding="utf-8")
            first = POLICY.scan_file(path)
            second = POLICY.scan_file(path)

        self.assertEqual(first, second)
        self.assertEqual([finding["line"] for finding in first], [1, 2])
        for finding in first:
            self.assertEqual(finding["path"], str(path).replace("\\", "/"))
            self.assertIn("kind", finding)
            self.assertIn("line", finding)

    def test_malformed_directive_is_reported_instead_of_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text("---@diagnostic disable-next-line\n", encoding="utf-8")
            findings = POLICY.scan_file(path)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["kind"], "malformed-directive")


if __name__ == "__main__":
    unittest.main()
