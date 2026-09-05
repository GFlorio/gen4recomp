-- Owns the concrete GPU, UI, and field-effect resources used by FieldState.

local FieldPresentationConfig = require("game.hgss.src.field.FieldPresentationConfig")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldMenuRenderer = require("libs.hgss.src.ui.FieldMenuRenderer")
local FieldSignpostRenderer = require("libs.hgss.src.ui.FieldSignpostRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldStaticEffectRenderer = require("libs.hgss.src.presentation.FieldStaticEffectRenderer")
local FieldActorEmoteRenderer = require("libs.hgss.src.presentation.FieldActorEmoteRenderer")
local FieldTerrainEffectRenderer = require("libs.hgss.src.presentation.FieldTerrainEffectRenderer")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local StartMenuRenderer = require("libs.hgss.src.ui.StartMenuRenderer")
local TrainerCardRenderer = require("libs.hgss.src.ui.TrainerCardRenderer")
local WindowConfig = require("game.src.WindowConfig")

---@class FieldPresentationResources
---@field renderer any
---@field dialogueRenderer any
---@field menuRenderer FieldMenuRenderer
---@field signpostRenderer FieldSignpostRenderer
---@field startMenuRenderer StartMenuRenderer
---@field trainerCardRenderer TrainerCardRenderer
---@field textRenderer FieldTextRenderer
---@field fieldEntranceIndicatorPool GpuAssetPool
---@field fieldEntranceIndicatorRenderer any
---@field fieldSurfRenderer any
---@field surfPresentation table<string, unknown>
---@field fieldEmotePool GpuAssetPool
---@field fieldEmoteRenderer any
---@field fieldTerrainEffectRenderer any
local FieldPresentationResources = {}
FieldPresentationResources.__index = FieldPresentationResources

---@param runtime table<string, unknown>
---@return FieldPresentationResources
function FieldPresentationResources.new(runtime)
  local self = setmetatable({}, FieldPresentationResources)
  local ok, err = pcall(function()
    self.renderer = FieldRenderer.new({
      clearColor = WindowConfig.BACKGROUND_COLOR,
      worldRasterScale = FieldPresentationConfig.WORLD_3D_RASTER_SCALE,
    })
    self.textRenderer = FieldTextRenderer.new({ cacheFs = runtime.cacheFs })
    self.dialogueRenderer = FieldDialogueRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = self.textRenderer,
    })
    self.menuRenderer = FieldMenuRenderer.new()
    self.signpostRenderer = FieldSignpostRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = self.textRenderer,
      windowStyles = runtime.windowStyles,
    })
    self.startMenuRenderer = StartMenuRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
    })
    self.trainerCardRenderer = TrainerCardRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = self.textRenderer,
    })
    self.fieldEntranceIndicatorPool = GpuAssetPool.new(runtime.cacheFs)
    self.fieldEntranceIndicatorRenderer =
      FieldStaticEffectRenderer.new(runtime.fieldEntranceIndicatorAsset.model, self.fieldEntranceIndicatorPool)
    local surfEffects = runtime.fieldEntranceIndicatorAsset and runtime.fieldEntranceIndicatorAsset.effects
    local surfAttachment =
      assert(surfEffects and surfEffects.surf_attachment, "field-effect cache is missing surf_attachment")
    self.surfPresentation = assert(surfAttachment.presentation, "field-effect cache is missing surf presentation")
    self.fieldSurfRenderer = FieldStaticEffectRenderer.new(surfAttachment.model, self.fieldEntranceIndicatorPool)
    self.fieldEmotePool = GpuAssetPool.new(runtime.cacheFs)
    self.fieldEmoteRenderer = FieldActorEmoteRenderer.new(runtime.fieldEmoteModels, self.fieldEmotePool)
    if runtime.fieldEffectAssets and runtime.fieldEffectAssets.effects then
      self.fieldTerrainEffectRenderer =
        FieldTerrainEffectRenderer.new(runtime.fieldEffectAssets, self.fieldEntranceIndicatorPool)
      local function terrainModelFactory(kind)
        return self.fieldTerrainEffectRenderer:newInstance(kind)
      end
      runtime.fieldTerrainEffectController:setModelFactory(terrainModelFactory)
    else
      local function emptyDrawItems()
        return {}
      end
      local function emptyDispose() end

      self.fieldTerrainEffectRenderer = {
        drawItems = emptyDrawItems,
        dispose = emptyDispose,
      }
    end
  end)
  if not ok then
    self:dispose()
    error(err, 0)
  end
  return self
end

function FieldPresentationResources:dispose()
  if self.dialogueRenderer then
    self.dialogueRenderer:release()
    self.dialogueRenderer = nil
  end
  if self.signpostRenderer then
    self.signpostRenderer:release()
    self.signpostRenderer = nil
  end
  if self.startMenuRenderer then
    self.startMenuRenderer:release()
    self.startMenuRenderer = nil
  end
  if self.trainerCardRenderer then
    self.trainerCardRenderer:release()
    self.trainerCardRenderer = nil
  end
  if self.textRenderer then
    self.textRenderer:release()
    self.textRenderer = nil
  end
  if self.fieldEntranceIndicatorRenderer then
    self.fieldEntranceIndicatorRenderer:dispose()
    self.fieldEntranceIndicatorRenderer = nil
  end
  if self.fieldSurfRenderer then
    self.fieldSurfRenderer:dispose()
    self.fieldSurfRenderer = nil
  end
  if self.fieldTerrainEffectRenderer then
    self.fieldTerrainEffectRenderer:dispose()
    self.fieldTerrainEffectRenderer = nil
  end
  if self.fieldEntranceIndicatorPool then
    self.fieldEntranceIndicatorPool:release()
    self.fieldEntranceIndicatorPool = nil
  end
  if self.fieldEmoteRenderer then
    self.fieldEmoteRenderer:dispose()
    self.fieldEmoteRenderer = nil
  end
  if self.fieldEmotePool then
    self.fieldEmotePool:release()
    self.fieldEmotePool = nil
  end
  if self.renderer then
    self.renderer:release()
    self.renderer = nil
  end
end

return FieldPresentationResources
