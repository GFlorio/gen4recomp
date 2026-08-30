-- Adapts HGSS field presentation state into the normalized frame consumed by
-- the concrete Nintendo DS LÖVE renderer.

local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")

---@class FieldRenderer
---@field gxRenderer GxRenderer
---@field stats table
---@field sceneColor GxRenderer.Canvas?
---@field renderState GxRenderer.Canvas?
---@field _ownsRenderer boolean
---@field _queueScratch RenderQueueScratch
local FieldRenderer = {}
FieldRenderer.__index = FieldRenderer

local DRAW_ITEM_FIELDS = {
  "mesh",
  "material",
  "transform",
  "modelNormal",
  "billboardCenter",
  "billboardScale",
  "alphaClass",
  "cullMode",
  "fogEnabled",
  "lightMask",
  "polygonAlpha",
  "polygonId",
  "polygonMode",
}

local function normalizedItem(item, projection)
  local normalized = { projection = projection }
  for _, field in ipairs(DRAW_ITEM_FIELDS) do
    normalized[field] = item[field]
  end
  return normalized
end

local function usesBillboardProjection(item)
  return item.billboardProjection == true or item.fieldEffect ~= nil
end

local function normalizedQueue(queue, worldProjection, billboardProjection)
  local normalized = {
    opaque = {},
    cutout = {},
    mixedOpaque = {},
    wireframe = {},
    blended = {},
  }
  for _, pass in ipairs({ "opaque", "cutout", "mixedOpaque", "wireframe" }) do
    for _, item in ipairs(queue[pass]) do
      local projection = usesBillboardProjection(item) and billboardProjection or worldProjection
      normalized[pass][#normalized[pass] + 1] = normalizedItem(item, projection)
    end
  end
  for _, entry in ipairs(queue.blended) do
    local item = entry.item
    local projection = usesBillboardProjection(item) and billboardProjection or worldProjection
    normalized.blended[#normalized.blended + 1] = {
      item = normalizedItem(item, projection),
      fragmentPass = entry.fragmentPass,
    }
  end
  return normalized
end

local function normalizedSprites(spriteItems, billboardProjection)
  if spriteItems == nil then
    return nil
  end
  local normalized = {}
  for _, item in ipairs(spriteItems) do
    normalized[#normalized + 1] = normalizedItem(item, billboardProjection)
  end
  return normalized
end

local function selectedLighting(sceneRuntime)
  local profile = sceneRuntime.lighting
  if profile == nil or profile.records == nil then
    return nil
  end
  return FieldLightProfile.select(profile, sceneRuntime.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS)
end

---@param opts table?
---@return FieldRenderer
function FieldRenderer.new(opts)
  opts = opts or {}
  local gxRenderer = opts.gxRenderer
  local ownsRenderer = gxRenderer == nil
  if gxRenderer == nil then
    gxRenderer = GxRenderer.new(opts)
  end
  return setmetatable({
    gxRenderer = gxRenderer,
    stats = gxRenderer.stats,
    _ownsRenderer = ownsRenderer,
    _queueScratch = {
      opaque = {},
      cutout = {},
      mixedOpaque = {},
      wireframe = {},
      blended = {},
    },
  }, FieldRenderer)
end

---@param sceneRuntime table
---@param camera table
---@param worldParts table[][]?
---@param spriteItems table[]?
---@param viewport table
---@param alpha number
function FieldRenderer:draw(sceneRuntime, camera, worldParts, spriteItems, viewport, alpha)
  assert(type(sceneRuntime) == "table", "field scene presentation is required")
  assert(type(camera) == "table", "field presentation camera is required")
  assert(type(camera.far) == "number" and camera.far > 0, "FieldRenderer requires camera.far to be a positive number")
  local viewMatrix = camera:view(alpha)
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()
  local queue = RenderQueue.buildInto(worldParts or {}, viewMatrix, self._queueScratch)
  self.gxRenderer:draw({
    lighting = selectedLighting(sceneRuntime),
    edgeColors = sceneRuntime.edgeColors,
    fog = sceneRuntime.fog,
    viewMatrix = viewMatrix,
    cameraZoom = camera.zoom,
    worldProjection = worldProjection,
    billboardProjection = billboardProjection,
    queue = normalizedQueue(queue, worldProjection, billboardProjection),
    spriteItems = normalizedSprites(spriteItems, billboardProjection),
    viewport = viewport,
  })
  self.sceneColor = self.gxRenderer.sceneColor
  self.renderState = self.gxRenderer.renderState
end

function FieldRenderer:release()
  if self._ownsRenderer then
    self.gxRenderer:release()
    self._ownsRenderer = false
  end
end

return FieldRenderer
