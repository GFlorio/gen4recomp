-- FieldApplicationRegistry contract tests: the per-runtime application
-- catalogue is populated before use and sealed; duplicate ids, registration
-- after sealing, unknown application ids, missing factories, and factories
-- returning partial controllers are composition errors. No process-global
-- registry exists: every instance is independent.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldApplicationRegistry = require("libs.engine.src.FieldApplicationRegistry")

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

local function sealedRegistry(descriptors)
  local registry = FieldApplicationRegistry.new()
  for _, entry in ipairs(descriptors) do
    registry:register(entry)
  end
  registry:seal()
  return registry
end

function T.tests.registries_are_per_runtime_instances()
  local first = FieldApplicationRegistry.new()
  local second = FieldApplicationRegistry.new()
  first:register(descriptor())
  first:seal()
  second:seal()
  Assert.equal(first:has("trainer_card"), true)
  Assert.equal(second:has("trainer_card"), false)
end

function T.tests.registration_validation_rejects_malformed_descriptors()
  local registry = FieldApplicationRegistry.new()
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    registry:register(descriptor({ id = "" }))
  end)
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    registry:register(descriptorWithout("id"))
  end)
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    registry:register(descriptorWithout("factory"))
  end)
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    registry:register(descriptor({ factory = "not a function" }))
  end)
  throwsCode("APPLICATION_REGISTRY_INVALID_DESCRIPTOR", function()
    local notATable = "not a table" ---@type any
    registry:register(notATable)
  end)
end

function T.tests.duplicate_ids_are_composition_errors()
  local registry = FieldApplicationRegistry.new()
  registry:register(descriptor())
  throwsCode("APPLICATION_REGISTRY_DUPLICATE_ID", function()
    registry:register(descriptor())
  end)
end

function T.tests.registration_after_sealing_is_a_composition_error()
  local registry = sealedRegistry({ descriptor() })
  throwsCode("APPLICATION_REGISTRY_ALREADY_SEALED", function()
    registry:register(descriptor({ id = "another" }))
  end)
end

function T.tests.double_sealing_is_rejected()
  local registry = FieldApplicationRegistry.new()
  registry:register(descriptor())
  registry:seal()
  throwsCode("APPLICATION_REGISTRY_ALREADY_SEALED", function()
    registry:seal()
  end)
end

function T.tests.queries_before_sealing_are_rejected()
  local registry = FieldApplicationRegistry.new()
  registry:register(descriptor())
  throwsCode("APPLICATION_REGISTRY_NOT_SEALED", function()
    registry:has("trainer_card")
  end)
  throwsCode("APPLICATION_REGISTRY_NOT_SEALED", function()
    registry:create("trainer_card")
  end)
end

function T.tests.has_answers_the_sealed_id_set()
  local registry = sealedRegistry({ descriptor() })
  Assert.equal(registry:has("trainer_card"), true)
  Assert.equal(registry:has("pokedex"), false)
  Assert.equal(registry.sealed, true)
end

function T.tests.create_returns_the_factory_result()
  local created
  local registry = sealedRegistry({
    descriptor({
      factory = function()
        created = fakeController()
        return created
      end,
    }),
  })
  Assert.equal(registry:create("trainer_card"), created)
end

function T.tests.create_passes_dispatch_arguments_to_the_factory()
  local received
  local registry = sealedRegistry({
    descriptor({
      factory = function(rememberedActionId)
        received = rememberedActionId
        return fakeController()
      end,
    }),
  })
  registry:create("trainer_card", "vanilla.trainer_card")
  Assert.equal(received, "vanilla.trainer_card")
end

function T.tests.unknown_application_ids_are_composition_errors()
  local registry = sealedRegistry({ descriptor() })
  throwsCode("APPLICATION_REGISTRY_UNKNOWN_ID", function()
    registry:create("pokedex")
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
    local registry = sealedRegistry({ descriptor({ factory = case.factory }) })
    throwsCode("APPLICATION_REGISTRY_INVALID_CONTROLLER", function()
      registry:create("trainer_card")
    end)
  end
end

return T
