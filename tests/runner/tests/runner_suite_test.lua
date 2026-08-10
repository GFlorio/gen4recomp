-- Contract tests for suite normalization. A mis-shaped module must be a loud
-- error, not a suite that silently contributes zero tests: the runner has no
-- registry left to notice the difference.

local Assert = require("tests.support.Assert")
local Suite = require("tests.runner.Suite")

local T = {}

local function normalize(mod, defaultLayer)
  return Suite.normalize(mod, "fake.unit.alpha_test", defaultLayer or "unit")
end

function T.legacy_module_takes_the_root_layer_and_declares_nothing()
  local suite = normalize({ ["b case"] = function() end, ["a case"] = function() end })

  Assert.equal(suite.layer, "unit")
  Assert.deepEqual(suite.tests, { "a case", "b case" })
  Assert.deepEqual(suite.capabilities, {})
  Assert.deepEqual(suite.tags, {})
  Assert.isNil(suite.beforeAll)
end

function T.explicit_metadata_overrides_the_root_layer()
  local suite = normalize({
    metadata = { layer = "graphics", capabilities = { "graphics" }, tags = { "renderer" } },
    beforeAll = function() end,
    tests = { ["compiles a shader"] = function() end },
  })

  Assert.equal(suite.layer, "graphics")
  Assert.deepEqual(suite.capabilities, { "graphics" })
  Assert.deepEqual(suite.tags, { "renderer" })
  Assert.deepEqual(suite.tests, { "compiles a shader" })
  Assert.equal(type(suite.beforeAll), "function")
end

-- A module carrying metadata or hooks but no `tests` table would otherwise
-- normalize to an empty legacy suite and report nothing at all.
function T.metadata_without_tests_is_rejected()
  local err = Assert.throws(function()
    normalize({ metadata = { layer = "rom" } })
  end)
  Assert.isTrue(tostring(err):find("tests table", 1, true) ~= nil, "names the missing tests table: " .. tostring(err))
end

function T.unknown_suite_and_metadata_keys_are_rejected()
  local suiteKey = Assert.throws(function()
    normalize({ tests = {}, setUp = function() end })
  end)
  Assert.isTrue(tostring(suiteKey):find("setUp", 1, true) ~= nil, "names the unknown key: " .. tostring(suiteKey))

  local metadataKey = Assert.throws(function()
    normalize({ metadata = { layers = "unit" }, tests = {} })
  end)
  Assert.isTrue(
    tostring(metadataKey):find("layers", 1, true) ~= nil,
    "names the unknown metadata key: " .. tostring(metadataKey)
  )
end

function T.non_function_test_entry_is_rejected()
  local err = Assert.throws(function()
    normalize({ tests = { ["not callable"] = "value" } })
  end)
  Assert.isTrue(tostring(err):find("not callable", 1, true) ~= nil, "names the offending test: " .. tostring(err))
end

return T
