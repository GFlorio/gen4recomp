-- Builds the initial concrete FieldRuntime state.

local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local FieldPresentation = require("data.manifests.field_presentation")
local LocalClock = require("game.src.LocalClock")
local RepoFs = require("game.src.RepoFs")
local WindowConfig = require("game.src.WindowConfig")

local FieldRuntimeComposition = {}

---@param game table<string, unknown>
---@param options table<string, unknown>?
---@return table<string, unknown>
function FieldRuntimeComposition.compose(game, options)
  assert(type(game) == "table", "field runtime requires a finalized or loaded game")
  assert(type(game.versionId) == "string" and game.versionId ~= "", "field runtime game version is required")
  options = options or {}
  local effectiveOverrideFs = options.overrideFs or RepoFs.new(love.filesystem.getSourceBaseDirectory())
  return {
    runtimeState = {
      game = game,
      versionId = game.versionId,
      saveId = game.saveId,
      viewportWidth = options.viewportWidth or WindowConfig.REFERENCE_WIDTH,
      viewportHeight = options.viewportHeight or WindowConfig.REFERENCE_HEIGHT,
      screenTopology = options.screenTopology,
      overrideFs = effectiveOverrideFs,
      presentation = options.presentation == true,
      scriptHosts = options.scriptHosts,
      dayNight = options.dayNight,
      audioOutput = options.audioOutput,
      saveStore = options.saveStore,
      saveValidation = options.saveValidation or GameSaveValidation.new({ overrideFs = effectiveOverrideFs }),
      savePublished = false,
      localClock = options.localClock or LocalClock.system(),
      weatherClock = options.weatherClock,
      errorText = nil,
      zoom = require("libs.hgss.src.presentation.FieldZoom").new(options.zoomConfig or FieldPresentation.zoom),
    },
  }
end

return FieldRuntimeComposition
