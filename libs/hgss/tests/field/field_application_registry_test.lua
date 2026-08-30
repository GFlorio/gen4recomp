-- FieldApplicationRegistry contract tests: the per-runtime application
-- catalogue is immutable after construction -- descriptors are validated at
-- new(), and has/create dispatch against the stored factory map. Duplicate
-- ids, malformed descriptors, unknown application ids, and factories
-- returning partial controllers are composition errors. No process-global
-- registry exists: every instance is independent.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldApplicationRegistry = require("libs.hgss.src.field.FieldApplicationRegistry")

local T = {
  tests = {},
}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local function fakeController()
  return {
    updateFixed = function() end,
    status = function()
      return {}
    end,
    takeResult = function() end,
    dispose = function() end,
  }
end

local function descriptor(overrides)
  local value = {
    id = "trainer_card",
    factory = function()
      return fakeController()
    end,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

-- A descriptor with one field explicitly removed (a pairs override cannot
-- express "absent": assigning nil deletes the key, which pairs skips).
local function descriptorWithout(field)
  local value = descriptor()
  value[field] = nil
  return value
end

local function registry(descriptors)
  return FieldApplicationRegistry.new(descriptors or {})
end

function T.tests.registries_are_per_runtime_instances()
  local first = registry({ descriptor() })
  local second = registry()
  Assert.equal(first:has("trainer_card"), true)
  Assert.equal(second:has("trainer_card"), false)
end

function T.tests.construction_validates_descriptors()
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    registry({ descriptor({ id = "" }) })
  end)
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    registry({ descriptorWithout("id") })
  end)
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    registry({ descriptorWithout("factory") })
  end)
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    registry({ descriptor({ factory = "not a function" }) })
  end)
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    local notATable = "not a table" ---@type any
    registry({ notATable })
  end)
end

function T.tests.duplicate_ids_are_composition_errors()
  throwsCode("APPLICATION_REGISTRY_DUPLICATE_ID", function()
    registry({ descriptor(), descriptor() })
  end)
end

function T.tests.has_answers_the_constructed_id_set()
  local applications = registry({ descriptor() })
  Assert.equal(applications:has("trainer_card"), true)
  Assert.equal(applications:has("pokedex"), false)
end

function T.tests.create_returns_the_factory_result()
  local created
  local applications = registry({
    descriptor({
      factory = function()
        created = fakeController()
        return created
      end,
    }),
  })
  Assert.equal(applications:create("trainer_card"), created)
end

function T.tests.create_calls_the_factory_with_only_the_application_id()
  local received
  local applications = registry({
    descriptor({
      factory = function(...)
        received = { n = select("#", ...), ... }
        return fakeController()
      end,
    }),
  })
  applications:create("trainer_card")
  Assert.equal(received.n, 0, "destinations receive no forwarded arguments -- the menu is not a registry entry")
end

function T.tests.unknown_application_ids_are_composition_errors()
  local applications = registry({ descriptor() })
  throwsCode("APPLICATION_REGISTRY_UNKNOWN_ID", function()
    applications:create("pokedex")
  end)
end

function T.tests.partial_controllers_are_composition_errors()
  local cases = {
    {
      factory = function()
        return nil
      end,
      label = "nil controller",
    },
    {
      factory = function()
        return "not a controller" ---@type any
      end,
      label = "non-table controller",
    },
    {
      factory = function()
        local controller = fakeController()
        controller.updateFixed = nil
        return controller
      end,
      label = "missing updateFixed",
    },
    {
      factory = function()
        local controller = fakeController()
        controller.status = nil
        return controller
      end,
      label = "missing status",
    },
    {
      factory = function()
        local controller = fakeController()
        controller.takeResult = nil
        return controller
      end,
      label = "missing takeResult",
    },
    {
      factory = function()
        local controller = fakeController()
        controller.dispose = nil
        return controller
      end,
      label = "missing dispose",
    },
  }
  for _, case in ipairs(cases) do
    local applications = registry({ descriptor({ factory = case.factory }) })
    throwsCode("APPLICATION_REGISTRY_INVALID_CONTROLLER", function()
      applications:create("trainer_card")
    end)
  end
end

return T
