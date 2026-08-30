-- Owns version-aware semantic validation for complete persisted GameSave
-- records and the PlayerData boundary used by an in-memory new game.

local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptSave = require("libs.script.src.ScriptSave")
local WorldState = require("libs.hgss.src.script.WorldState")
local AuxiliaryFieldUi = require("libs.hgss.src.ui.AuxiliaryFieldUi")
local FieldAudioSave = require("libs.hgss.src.audio.FieldAudioSave")
local AudioCache = require("libs.assets.src.AudioCache")
local GameSave = require("libs.hgss.src.save.GameSave")
local Errors = require("libs.errors.src.Errors")
local FieldScriptCompatibility = require("game.src.game.FieldScriptCompatibility")

---@class GameSaveValidation
---@field contexts table<string, table>
---@field contextLoader fun(versionId: string): table
---@field overrideFs table|nil repository override filesystem for default contexts
local GameSaveValidation = {}
GameSaveValidation.__index = GameSaveValidation

---@param cacheFs CacheFs
---@param overrideFs table
---@return table
local function contextForCache(cacheFs, overrideFs)
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
  local index = assert(cacheFs:loadLua(AudioCache.indexPath()), "audio index missing")
  assert(index.schema == AudioCache.INDEX_SCHEMA, "audio index schema is invalid")
  assert(type(index.sequences) == "table", "audio index sequences are required")
  local audioSequenceIds = {}
  for sequenceId, sequence in pairs(index.sequences) do
    assert(type(sequenceId) == "number" and sequence.id == sequenceId, "audio index sequence identity is invalid")
    audioSequenceIds[sequenceId] = true
  end
  return {
    charmap = fontDef.charmap,
    frameIndexes = frameIndexes,
    audioSequenceIds = audioSequenceIds,
    scriptCompatibility = FieldScriptCompatibility.new({ cacheFs = cacheFs, overrideFs = overrideFs }),
  }
end

---@param options table?
---@return GameSaveValidation
function GameSaveValidation.new(options)
  options = options or {}
  return setmetatable({
    contexts = {},
    contextLoader = options.contextLoader,
    overrideFs = options.overrideFs,
  }, GameSaveValidation)
end

function GameSaveValidation:_context(versionId)
  local context = self.contexts[versionId]
  if context then
    return context
  end
  context = self.contextLoader and self.contextLoader(versionId)
    or contextForCache(CacheFs.forVersion(versionId), assert(self.overrideFs, "override filesystem is required"))
  assert(type(context) == "table", "GameSave validation context must be a table")
  assert(type(context.audioSequenceIds) == "table", "GameSave validation audio sequence ids are required")
  assert(type(context.scriptCompatibility) == "table", "GameSave script compatibility context is required")
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
    local function playerDataValidate(value)
      return PlayerData.validate(value, selected)
    end
    local function scriptsValidate(value)
      local options = selected.scriptCompatibility:validationOptions()
      return ScriptSave.validate(value, options)
    end
    local function worldValidate(value)
      return WorldState.validate(value)
    end
    local function auxiliaryUiValidate(value)
      return AuxiliaryFieldUi.validate(value)
    end
    local function audioValidate(value)
      return FieldAudioSave.validate(value, selected)
    end
    return GameSave.validate(record, {
      playerDataValidate = playerDataValidate,
      scriptsValidate = scriptsValidate,
      worldValidate = worldValidate,
      auxiliaryUiValidate = auxiliaryUiValidate,
      audioValidate = audioValidate,
    })
  end)
  if ok then
    return result, err
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
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
