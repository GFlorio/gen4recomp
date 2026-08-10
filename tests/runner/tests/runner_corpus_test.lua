-- Guards the aggregate entry point against silently discovering nothing. The
-- fake-corpus suites prove the discovery rules; this one proves they are wired
-- to the real repository: every declared root contributes suites, nested script
-- suites are reachable, and no suite is listed without tests or a layer.

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

function T.every_declared_root_contributes_suites()
  local counts = {}
  for _, suite in ipairs(corpus()) do
    for _, root in ipairs(Runner.ROOTS) do
      if suite.module:sub(1, #root.prefix + 1) == root.prefix .. "." then
        counts[root.path] = (counts[root.path] or 0) + 1
      end
    end
  end
  for _, root in ipairs(Runner.ROOTS) do
    Assert.isTrue((counts[root.path] or 0) > 0, "root discovered no suites: " .. root.path)
  end
end

-- Both suffix spellings exist in the repository; the nested script suites use
-- the plural one and were previously registered by hand.
function T.nested_script_suites_are_discovered()
  Assert.notNil(find("libs.engine.tests.script.scheduler_tests"), "nested plural suite is missing")
  Assert.notNil(find("libs.engine.tests.field_session_test"), "immediate suite is missing")
end

function T.every_listed_suite_has_a_layer_and_tests()
  for _, suite in ipairs(corpus()) do
    Assert.isTrue(type(suite.layer) == "string" and suite.layer ~= "", "suite without a layer: " .. suite.module)
    Assert.isTrue(#suite.tests > 0, "suite without tests: " .. suite.module)
  end
end

return T
