-- Presents the persistent surfing attachment relative to the player's
-- interpolated render position. The presentation owner keeps the GPU pool;
-- this adapter only assembles world-space draw items from the current surf
-- status, translating the shared static model to the player anchor plus the
-- live attachment offset and yawing it by the player's facing.

local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

local Renderer = {}
Renderer.__index = Renderer

local function materials(asset, pool)
  local out = {}
  for _, record in ipairs(asset.model.materials) do
    local wrap = SceneDescriptor.wrap(record)
    out[record.id] = {
      id = record.id,
      name = record.name,
      image = pool:imageFor(record.texture, wrap.x, wrap.y),
      texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
      wrap = wrap,
    }
  end
  return out
end

---@param definition { model: table, presentation: table }
---@param pool table
---@return table
function Renderer.new(definition, pool)
  assert(
    definition and definition.model and definition.model.batches and definition.model.materials,
    "player surf renderer requires a static attachment model"
  )
  assert(
    definition.presentation and definition.presentation.yawDegrees,
    "player surf renderer requires a surf presentation definition"
  )
  assert(pool and pool.meshFor and pool.imageFor and pool.build, "player surf renderer requires an asset pool")
  local prepared = pool:build(function()
    local materialById = materials({ model = definition.model }, pool)
    local batches = {}
    for _, batch in ipairs(definition.model.batches) do
      local mesh = pool:meshFor(batch.geometry)
      batches[#batches + 1] = {
        mesh = mesh.mesh,
        material = materialById[batch.material],
        center = mesh.center,
        alphaClass = batch.alphaClass,
        cullMode = batch.cullMode,
        polygonAlpha = batch.polygonAlpha / FixedPoint.RGB5_MAX,
        polygonMode = batch.polygonMode,
        polygonId = batch.polygonId,
        translucentDepthWrite = batch.translucentDepthWrite,
        depthEqual = batch.depthEqual,
        lightMask = batch.lightMask,
        fogEnabled = batch.fogEnabled,
      }
    end
    return { batches = batches, yawDegrees = definition.presentation.yawDegrees }
  end)
  return setmetatable({ prepared = prepared }, Renderer)
end

---@param status { active: boolean, position: { x: number, y: number, z: number }?, facing: string?, attachmentOffsetY: number? }
---@return table[]
function Renderer:drawItems(status)
  if not status or not status.active then
    return {}
  end
  local position = status.position
  if position == nil then
    return {}
  end
  local yawDegrees = self.prepared.yawDegrees[status.facing or "south"] or 0
  local transform = Matrix4.multiply(
    Matrix4.translate(position.x, position.y + (status.attachmentOffsetY or 0), position.z),
    Matrix4.rotateY(math.rad(yawDegrees))
  )
  local items = {}
  for _, batch in ipairs(self.prepared.batches) do
    items[#items + 1] = {
      mesh = batch.mesh,
      material = batch.material,
      transform = transform,
      modelNormal = Matrix3.modelNormal(transform),
      center = batch.center,
      alphaClass = batch.alphaClass,
      cullMode = batch.cullMode,
      polygonAlpha = batch.polygonAlpha,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      fogEnabled = batch.fogEnabled,
      worldSpace = true,
      fieldEffect = "surf_attachment",
    }
  end
  return items
end

function Renderer:dispose()
  self.prepared = nil
end

return Renderer
