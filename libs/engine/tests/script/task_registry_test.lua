-- TaskRegistry registration tests : registration-time invariants for
-- versioned task implementations (integer version, required `validate`,
-- function-typed optional `cancel`/`onComplete`) and the documented
-- version-bump requirement for serialized-state shape changes.

local Assert = require("tests.support.Assert")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")

local T = {}

-- A valid minimal implementation; `overrides` replace fields.
---@param overrides table|nil
---@return table
local function impl(overrides)
  local base = {
    version = 1,
    create = function()
      return {}
    end,
    poll = function()
      return { complete = false, state = {} }
    end,
    validate = function()
      return nil
    end,
  }
  for field, value in pairs(overrides or {}) do
    base[field] = value
  end
  return base
end

---@param pattern string
---@param fn function
local function assertRaises(pattern, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  Assert.isTrue(
    tostring(err):match(pattern) ~= nil,
    "expected error matching " .. pattern .. ", got: " .. tostring(err)
  )
end

-- 1. A fractional version is a programming invariant, not a distinct task
-- version: 1.5 must be rejected while 1 stays registerable, and the
-- duplicate type/version registration stays rejected.
T["fractional version rejected"] = function()
  local registry = TaskRegistry.new()
  assertRaises("task version must be an integer", function()
    registry:register("test.fractional", 1.5, impl())
  end)
  registry:register("test.fractional", 1, impl())
  Assert.notNil(registry:resolve("test.fractional", 1))
  assertRaises("registered twice", function()
    registry:register("test.fractional", 1, impl())
  end)
end

-- 2. `validate` is required, not optional: a missing or non-function
-- implementation is rejected at registration.
T["validate required"] = function()
  local registry = TaskRegistry.new()
  assertRaises("task implementation must supply validate", function()
    local noValidate = {
      version = 1,
      create = function()
        return {}
      end,
      poll = function()
        return { complete = false, state = {} }
      end,
    } --[[@as any]]
    registry:register("test.novalidate", 1, noValidate)
  end)
  assertRaises("task implementation must supply validate", function()
    registry:register("test.badvalidate", 1, impl({ validate = 42 }))
  end)
end

-- 3. Optional callbacks are validated when present: a non-function
-- `cancel`/`onComplete` is rejected, a function-valued pair registers.
T["malformed optional callbacks rejected"] = function()
  local registry = TaskRegistry.new()
  assertRaises("task implementation must supply a function cancel", function()
    registry:register("test.badcancel", 1, impl({ cancel = "not a function" }))
  end)
  assertRaises("task implementation must supply a function onComplete", function()
    registry:register("test.badcomplete", 1, impl({ onComplete = 42 }))
  end)
  registry:register("test.callbacks", 1, impl({ cancel = function() end, onComplete = function() end }))
  local resolved = assert(registry:resolve("test.callbacks", 1))
  Assert.isTrue(type(resolved.cancel) == "function")
  Assert.isTrue(type(resolved.onComplete) == "function")
end

-- 4. types() enumerates every registered type exactly once, sorted by
-- name, including types with multiple registered versions.
T["types enumerates registered types"] = function()
  local registry = TaskRegistry.new()
  registry:register("test.z", 1, impl())
  registry:register("test.a", 1, impl())
  registry:register("test.z", 2, impl())
  Assert.deepEqual(registry:types(), { "test.a", "test.z" })
end

-- 5. Both optional callbacks may be omitted entirely; a minimal
-- create/poll/validate implementation is accepted.
T["optional callbacks omitted accepted"] = function()
  local registry = TaskRegistry.new()
  registry:register("test.minimal", 1, {
    type = "test.minimal",
    version = 1,
    create = function()
      return {}
    end,
    poll = function()
      return { complete = false, state = {} }
    end,
    validate = function()
      return nil
    end,
  })
  Assert.notNil(registry:resolve("test.minimal", 1))
end

return T
