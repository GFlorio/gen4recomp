-- Tests for FieldScriptSymbols: the project-owned script-symbol contract
-- (flag and variable names resolve to HGSS ids). The script platform and any
-- mod script resolve symbolic references through this name -> id surface; the
-- frozen source catalogs live in romdump and derive their id -> name view
-- from this module.

local Assert = require("tests.support.Assert")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {}

function T.schema_is_stable()
  Assert.equal(FieldScriptSymbols.schema, "g4-script-symbols-v1")
end

function T.resolves_known_flag_symbols()
  Assert.equal(FieldScriptSymbols.flagsByName.FLAG_ACTION_CLEAR, 0)
  Assert.equal(FieldScriptSymbols.flagsByName.FLAG_MAPTEMP_003, 3)
  Assert.equal(FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER, 106)
end

function T.resolves_known_variable_symbols()
  Assert.equal(FieldScriptSymbols.variablesByName.VAR_BASE, 16384)
  Assert.equal(FieldScriptSymbols.variablesByName.VAR_OBJ_0, 16416)
  Assert.equal(FieldScriptSymbols.variablesByName.VAR_BATTLE_RESULT, 16403)
end

function T.every_symbol_is_a_distinct_integer_id()
  local function check(catalog)
    local ids = {} ---@type table<number, boolean>
    for name, id in pairs(catalog) do
      Assert.isTrue(type(name) == "string" and name ~= "", "symbol names are non-empty strings")
      Assert.isTrue(
        type(id) == "number" and id == math.floor(id) and id >= 0 and id <= 65535,
        "symbol ids are u16 integers"
      )
      Assert.isNil(ids[id], "duplicate id " .. id)
      ids[id] = true
    end
  end
  check(FieldScriptSymbols.flagsByName)
  check(FieldScriptSymbols.variablesByName)
  Assert.isTrue(next(FieldScriptSymbols.flagsByName) ~= nil, "flag catalog is non-empty")
  Assert.isTrue(next(FieldScriptSymbols.variablesByName) ~= nil, "variable catalog is non-empty")
end

function T.unknown_symbols_are_absent()
  Assert.isNil(FieldScriptSymbols.flagsByName["FLAG_NOT_A_REAL_SYMBOL"])
  Assert.isNil(FieldScriptSymbols.variablesByName["VAR_NOT_A_REAL_SYMBOL"])
end

return { tests = T }
