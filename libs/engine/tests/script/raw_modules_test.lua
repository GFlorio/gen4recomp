-- RawModules tests: the ownership-aware raw module registry's
-- register/resolve/moduleNames contracts and the post-load seal gate — once
-- sealed, registration is rejected while resolution stays live.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local RawModules = require("libs.engine.src.script.RawModules")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  Assert.isTrue(Errors.is(err), "expected Errors object, got: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
end

-- 1. A duplicate registration is a hard attributed error.
T["duplicate registration is rejected"] = function()
  local modules = RawModules.new()
  modules:register("mod.handler", { handle = function() end }, { modId = "mod.a" })
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    modules:register("mod.handler", { handle = function() end }, { modId = "mod.b" })
  end)
end

-- 2. Once sealed, registration is rejected while resolution and module
-- listing stay live.
T["sealed modules reject registration but still resolve"] = function()
  local modules = RawModules.new()
  local module = { handle = function() end }
  modules:register("mod.handler", module, { modId = "mod.a" })
  modules:seal()
  throwsCode("SCRIPT_RAW_MODULES_SEALED", function()
    modules:register("late.handler", { handle = function() end }, { modId = "mod.a" })
  end)
  local resolved = modules:resolve("mod.handler")
  Assert.equal(resolved, module)
  Assert.deepEqual(modules:moduleNames(), { "mod.handler" })
end

return T
