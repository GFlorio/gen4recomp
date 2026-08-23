-- Graphics regression for the canonical warp-entrance effect. The test loads
-- the normalized cached model through the production GPU pool and indicator
-- adapter, then sends its draw items through MapRenderer over a bright target.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local FieldCamera = require("libs.engine.src.FieldCamera")
local FieldEntranceIndicatorRenderer = require("libs.engine.src.FieldEntranceIndicatorRenderer")
local FieldViewport = require("libs.engine.src.FieldViewport")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")
local MapRenderer = require("libs.engine.src.MapRenderer")

local T = {}

local function runtime()
  local fogTable = {}
  for i = 1, 32 do
    fogTable[i] = 0
  end
  return {
    mapDraws = {},
    buildingDraws = {},
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
end

function T.canonical_indicator_preserves_bright_background(scope, context)
  local cache = CacheFs.forVersion("heartgold")
  if not cache:exists(FieldEffectAssetCache.modelPath()) then
    context:skip("canonical field-effect model is unavailable")
    return
  end

  local model = assert(cache:loadLua(FieldEffectAssetCache.modelPath()))
  local cameraProfiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
  local fieldCamera = FieldCamera.new(cameraProfiles.profiles[0], { canonicalAspect = 4 / 3 })
  local pool = scope:own(GpuAssetPool.new(cache))
  local indicator = FieldEntranceIndicatorRenderer.new(model, pool)
  scope:own({
    release = function()
      indicator:dispose()
    end,
  })
  local items = indicator:drawItems({
    visible = true,
    position = { x = 0, y = 0, z = 0 },
    rotationDegrees = 0,
    scale = 1,
  })
  Assert.isTrue(#items > 0, "canonical indicator must produce a draw item")
  local renderer = scope:own(MapRenderer.new({ clearColor = { 0.2, 0.7, 0.9, 1 } }))
  local target = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(target)
  love.graphics.clear(0.2, 0.7, 0.9, 1)
  renderer:draw(runtime(), fieldCamera, { items }, nil, FieldViewport.new(256, 192, { mode = "strict" }), nil)
  love.graphics.setCanvas()

  local image = target:newImageData()
  local background, changed = 0, 0
  local minX, minY = image:getWidth(), image:getHeight()
  local maxX, maxY = -1, -1
  local pixels = {}
  for y = 0, image:getHeight() - 1 do
    for x = 0, image:getWidth() - 1 do
      local r, g, b = image:getPixel(x, y)
      local isBackground = math.abs(r - 0.2) < 0.02 and math.abs(g - 0.7) < 0.02 and math.abs(b - 0.9) < 0.02
      pixels[y] = pixels[y] or {}
      pixels[y][x] = isBackground
      if not isBackground then
        changed = changed + 1
        minX, minY = math.min(minX, x), math.min(minY, y)
        maxX, maxY = math.max(maxX, x), math.max(maxY, y)
      end
    end
  end
  Assert.isTrue(
    changed > 0,
    "the canonical indicator must render visible arrow pixels (background=" .. background .. ")"
  )
  for y = minY, maxY do
    for x = minX, maxX do
      if pixels[y][x] then
        background = background + 1
      end
    end
  end
  Assert.isTrue(
    background > 0,
    string.format(
      "transparent indicator coverage must preserve the bright background inside the rendered effect bounds (changed=%d, bounds=%d,%d-%d,%d, background=%d)",
      changed,
      minX,
      minY,
      maxX,
      maxY,
      background
    )
  )
end

return GraphicsSmoke.suite(T)
