-- Presentation adapter for the normalized directional entrance effect. The
-- field presentation owns the GPU pool; this adapter only assembles
-- world-space draw items from the current indicator status.

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

function Renderer.new(model, pool)
  assert(model and model.batches and model.materials, "field effect asset model is required")
  assert(pool and pool.meshFor and pool.imageFor and pool.build, "field effect asset pool is required")
  local prepared = pool:build(function()
    local materialById = materials({ model = model }, pool)
    local batches = {}
    for _, batch in ipairs(model.batches) do
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
    return { model = model, batches = batches }
  end)
  return setmetatable({ prepared = prepared }, Renderer)
end

function Renderer:drawItems(status)
  if not status or not status.visible or not status.position then
    return {}
  end
  local transform = Matrix4.multiply(
    Matrix4.translate(status.position.x, status.position.y, status.position.z),
    Matrix4.multiply(
      Matrix4.rotateY(math.rad(status.rotationDegrees)),
      Matrix4.scale(status.scale, status.scale, status.scale)
    )
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
      fieldEffect = status.fieldEffect or "warp_entrance",
    }
  end
  return items
end

function Renderer:dispose()
  self.prepared = nil
end

return Renderer
