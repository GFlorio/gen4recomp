-- StarterChoiceTask contract tests : the example raw-extension task's
-- create/spec validation. An invalid initial selection (non-number,
-- non-integer, or out of range) is a schema fault, never a silent reset to
-- the first choice. The task lives at tests/examples/StarterChoiceTask.lua,
-- outside the production task registry, until a real starter-selection
-- subsystem owns it.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local StarterChoiceTask = require("tests.examples.StarterChoiceTask")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

local function ctx()
  return { instance = { scriptId = 1 } }
end

-- 1. An invalid initial selection is a schema fault, not a silent reset to
-- the first choice (below range, above range, and fractional).
T["invalid initial selection raises"] = function()
  throwsCode(ScriptErrors.SCRIPT_SCHEMA_INVALID, function()
    StarterChoiceTask.create({ selection = 0 }, ctx())
  end)
  throwsCode(ScriptErrors.SCRIPT_SCHEMA_INVALID, function()
    StarterChoiceTask.create({ selection = 4 }, ctx())
  end)
  throwsCode(ScriptErrors.SCRIPT_SCHEMA_INVALID, function()
    StarterChoiceTask.create({ selection = 1.5 }, ctx())
  end)
end

-- 2. The default and explicitly valid selections still construct.
T["valid selections are preserved"] = function()
  local state = StarterChoiceTask.create({}, ctx())
  Assert.equal(state.selection, 1)
  Assert.equal(state.phase, "choosing")
  Assert.equal(#state.choices, 3)
  local chosen = StarterChoiceTask.create({ selection = 2 }, ctx())
  Assert.equal(chosen.selection, 2)
end

return T
