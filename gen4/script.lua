-- Public gen4 field-script DSL, API 1: the current module version, still
-- under development, and the only import mods and content use:
--
--     local S = require("gen4.script")
--
-- It re-exports every DSL constructor plus the API version constant and a
-- development `validate` helper, and must never expose the physical engine
-- directory layout. API 1 is not declared stable: constructor shapes,
-- operation names, field names, and defaults may change in a future API
-- version, and libs/engine/tests/script pins the current shapes verbatim.

local Dsl = require("libs.engine.src.script.Dsl")
local Schema = require("libs.engine.src.script.Schema")
local Validator = require("libs.engine.src.script.Validator")

local S = {}

for name, constructor in pairs(Dsl) do
  S[name] = constructor
end

S.apiVersion = Schema.API_VERSION

-- Development helper: validates a script resource without a game session.
-- Returns true, or nil plus an Errors object with code SCRIPT_* and a
-- `path`-attributed context. Strict mode (the default) rejects unknown fields;
-- generated content always validates in strict mode.
---@param script any
---@param opts table|nil
---@return boolean|nil, Errors.Error|nil
function S.validate(script, opts)
  return Validator.validate(script, opts)
end

return S
