-- Guards the aggregate entry point against silently discovering nothing. The
-- fake-corpus suites prove the discovery rules; this one proves they are wired
-- to the real repository and nested suites are reachable.

local Assert = require("tests.support.Assert")
local Runner = require("tests.run")

local T = {}

local listing = nil

local function corpus()
  if listing == nil then
    listing = Runner.list({})
  end
  return listing
end

local function find(moduleName)
  for _, suite in ipairs(corpus()) do
    if suite.module == moduleName then
      return suite
    end
  end
  return nil
end

function T.project_tree_discovery_finds_the_main_test_trees()
  local expected = {
    "libs.codec.tests.binary_reader_test",
    "game.tests.field_state_draw_test",
    "romdump.tests.source.narc_test",
    "tests.runner.tests.runner_discovery_test",
  }
  for _, moduleName in ipairs(expected) do
    Assert.notNil(find(moduleName), "project tree discovery missed " .. moduleName)
  end
end

-- Discovery reaches nested script suites through the `_test.lua` suffix.
function T.nested_script_suites_are_discovered()
  Assert.notNil(find("libs.script.tests.core.scheduler_test"), "nested script suite is missing")
  Assert.notNil(find("libs.engine.tests.field_session_test"), "immediate suite is missing")
end

function T.every_listed_suite_has_a_layer_and_tests()
  for _, suite in ipairs(corpus()) do
    Assert.isTrue(type(suite.layer) == "string" and suite.layer ~= "", "suite without a layer: " .. suite.module)
    Assert.isTrue(#suite.tests > 0, "suite without tests: " .. suite.module)
  end
end

return { tests = T }
