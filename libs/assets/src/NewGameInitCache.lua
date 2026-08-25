-- Cache schema, path, and strict validator for the generated fresh-game
-- startup event initializer: the source `_std_init` standard script's
-- `SetFlag` operations resolved to numeric event-flag ids, plus the one
-- recognized non-field-state startup side effect (`LotoIDSet`). Runtime
-- applies `eventOperations` once to a finalized fresh New Game candidate
-- before `FieldRuntime` construction; it never hand-maintains this flag
-- list. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")

local NewGameInitCache = {}

NewGameInitCache.FORMAT = Contract.newGameInit.cacheFormat
NewGameInitCache.SCHEMA = Contract.newGameInit.schema

local ARTIFACT_INVALID = "NEW_GAME_INIT_ARTIFACT_INVALID"

local DATA_DIR = "data/generated/new_game"

-- The only source startup command not modeled as field-event state in this
-- scope; see romdump NewGameInitCompiler for why it is bounded rather than
-- implemented.
local RECOGNIZED_NON_FIELD_EFFECTS = { LotoIDSet = true }

function NewGameInitCache.dir()
  return DATA_DIR
end

function NewGameInitCache.path()
  return DATA_DIR .. "/init.lua"
end

function NewGameInitCache.markerPath()
  return DATA_DIR .. "/complete"
end

function NewGameInitCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", NewGameInitCache.FORMAT, romSha1, depHash)
end

local function validateOperation(index, operation)
  if type(operation) ~= "table" then
    return false, Errors.new(ARTIFACT_INVALID, "event operation " .. index .. " must be a table", { index = index })
  end
  if operation.op ~= "set_flag" then
    return false,
      Errors.new(ARTIFACT_INVALID, "event operation " .. index .. " has unknown op " .. tostring(operation.op), {
        index = index,
        op = operation.op,
      })
  end
  if type(operation.id) ~= "number" or operation.id ~= math.floor(operation.id) or operation.id < 0 then
    return false,
      Errors.new(ARTIFACT_INVALID, "event operation " .. index .. " id must be a non-negative integer", {
        index = index,
      })
  end
  if operation.symbol ~= nil and type(operation.symbol) ~= "string" then
    return false,
      Errors.new(ARTIFACT_INVALID, "event operation " .. index .. " symbol must be a string", { index = index })
  end
  return true
end

-- Strict artifact validation: shared by the writer's readback and by runtime
-- loading. Returns true on success, false, err otherwise.
function NewGameInitCache.validate(artifact)
  if type(artifact) ~= "table" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact is not a table", {})
  end
  if artifact.schema ~= NewGameInitCache.SCHEMA then
    return false,
      Errors.new(ARTIFACT_INVALID, "artifact schema mismatch", {
        schema = artifact.schema,
        expected = NewGameInitCache.SCHEMA,
      })
  end
  if type(artifact.versionId) ~= "string" or artifact.versionId == "" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact versionId must be a non-empty string", {})
  end
  if type(artifact.eventOperations) ~= "table" or #artifact.eventOperations == 0 then
    return false, Errors.new(ARTIFACT_INVALID, "artifact eventOperations must be a non-empty array", {})
  end
  for index, operation in ipairs(artifact.eventOperations) do
    local ok, err = validateOperation(index, operation)
    if not ok then
      return false, err
    end
  end
  if type(artifact.nonFieldEffects) ~= "table" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact nonFieldEffects must be a table", {})
  end
  for index, effect in ipairs(artifact.nonFieldEffects) do
    if type(effect) ~= "string" or not RECOGNIZED_NON_FIELD_EFFECTS[effect] then
      return false,
        Errors.new(ARTIFACT_INVALID, "artifact nonFieldEffects " .. index .. " is unrecognized: " .. tostring(effect), {
          index = index,
          effect = effect,
        })
    end
  end
  if type(artifact.sourceDependency) ~= "table" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact sourceDependency must be a table", {})
  end
  local member = artifact.sourceDependency.standardScriptMember
  if type(member) ~= "number" or member ~= math.floor(member) or member < 0 then
    return false,
      Errors.new(ARTIFACT_INVALID, "artifact sourceDependency.standardScriptMember must be a non-negative integer", {})
  end
  return true
end

function NewGameInitCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(NewGameInitCache.markerPath()) ~= expectedMarker then
    return false
  end
  local artifact = cacheFs:loadLua(NewGameInitCache.path())
  if type(artifact) ~= "table" then
    return false
  end
  return NewGameInitCache.validate(artifact) == true
end

return NewGameInitCache
