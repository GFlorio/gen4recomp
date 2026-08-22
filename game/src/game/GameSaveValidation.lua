-- Owns version-aware semantic validation for complete persisted GameSave
-- records and the PlayerData boundary used by an in-memory new game.

local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local PlayerData = require("libs.engine.src.PlayerData")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local GameSave = require("libs.engine.src.GameSave")
local Errors = require("libs.errors.src.Errors")

---@class GameSaveValidation
---@field contexts table<string, table>
---@field contextLoader fun(versionId: string): table
local GameSaveValidation = {}
GameSaveValidation.__index = GameSaveValidation

local function contextForCache(cacheFs)
  local fontDef = FieldFontLoader.load(cacheFs)
  local manifest, loadError = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
  if not manifest then
    error(loadError)
  end
  local valid, err = FieldUiAssetCache.validateManifest(manifest)
  if not valid then
    error(err)
  end
  local frameIndexes = {}
  for frame = 0, manifest.dialogueFrames.count - 1 do
    frameIndexes[frame] = true
  end
  return { charmap = fontDef.charmap, frameIndexes = frameIndexes }
end

---@param options table?
---@return GameSaveValidation
function GameSaveValidation.new(options)
  options = options or {}
  return setmetatable({ contexts = {}, contextLoader = options.contextLoader }, GameSaveValidation)
end

function GameSaveValidation:_context(versionId)
  local context = self.contexts[versionId]
  if context then
    return context
  end
  context = self.contextLoader and self.contextLoader(versionId) or contextForCache(CacheFs.forVersion(versionId))
  assert(type(context) == "table", "GameSave validation context must be a table")
  self.contexts[versionId] = context
  return context
end

---@param record table
---@param context table?
---@return table|nil, Errors.Error?
function GameSaveValidation:validate(record, context)
  local ok, result, err = pcall(function()
    if context == nil and (type(record) ~= "table" or type(record.versionId) ~= "string") then
      return GameSave.validate(record)
    end
    local selected = context or self:_context(record.versionId)
    return GameSave.validate(record, {
      playerDataValidate = function(value)
        return PlayerData.validate(value, selected)
      end,
      scriptsValidate = function(value)
        return ScriptSave.validate(value, {})
      end,
    })
  end)
  if ok then
    return result, err
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

function GameSaveValidation:validatePlayerData(playerData, context)
  local ok, result, err = pcall(function()
    return PlayerData.validate(playerData, context)
  end)
  if ok then
    return result, err
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return GameSaveValidation
