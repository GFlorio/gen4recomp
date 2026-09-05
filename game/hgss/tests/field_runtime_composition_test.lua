-- FieldRuntime keeps construction, swap, save, and script composition behind
-- explicit private owners.

local Assert = require("tests.support.Assert")

local T = {}

local OWNER_MODULES = {
  "game.hgss.src.field.FieldRuntimeComposition",
  "game.hgss.src.field.FieldWorldSwapCoordinator",
  "game.hgss.src.field.FieldSaveCoordinator",
  "game.hgss.src.field.FieldScriptComposition",
}

function T.runtime_composition_owners_are_loadable()
  for _, moduleName in ipairs(OWNER_MODULES) do
    local ok, owner = pcall(require, moduleName)
    Assert.isTrue(ok, moduleName .. " must be a loadable private owner: " .. tostring(owner))
    Assert.equal(type(owner), "table", moduleName .. " must expose a module table")
  end
end

function T.runtime_composition_owners_expose_their_narrow_operations()
  local Composition = require("game.hgss.src.field.FieldRuntimeComposition")
  local WorldSwap = require("game.hgss.src.field.FieldWorldSwapCoordinator")
  local Save = require("game.hgss.src.field.FieldSaveCoordinator")
  local Scripts = require("game.hgss.src.field.FieldScriptComposition")

  Assert.equal(type(Composition.compose), "function")
  Assert.equal(type(WorldSwap.new), "function")
  Assert.equal(type(WorldSwap.prepare), "function")
  Assert.equal(type(WorldSwap.commit), "function")
  Assert.equal(type(WorldSwap.abort), "function")
  Assert.equal(type(Save.new), "function")
  Assert.equal(type(Scripts.compose), "function")
end

return { tests = T }
