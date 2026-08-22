-- Presentation adapter for the normalized directional entrance effect. The
-- map scene's GPU pool owns meshes/images; this adapter only assembles
-- world-space draw items from the current indicator status.

local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local SceneDescriptor = require("libs.engine.src.SceneDescriptor")

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(asset)
  assert(asset and asset.model and asset.model.batches, "field effect asset model is required")
  return setmetatable({ asset = asset }, Renderer)
end

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

function Renderer:drawItems(status, sceneRuntime)
  if not status or not status.visible then
    return {}
  end
  assert(sceneRuntime and sceneRuntime.assetPool, "field effect requires the live scene asset pool")
  local pool = sceneRuntime.assetPool
  local materialById = materials(self.asset, pool)
  local transform = Matrix4.multiply(
    Matrix4.translate(status.position.x, status.position.y, status.position.z),
    Matrix4.multiply(
      Matrix4.rotateY(math.rad(status.rotationDegrees)),
      Matrix4.scale(status.scale, status.scale, status.scale)
    )
  )
  local items = {}
  for _, batch in ipairs(self.asset.model.batches) do
    local mesh = pool:meshFor(batch.geometry)
    items[#items + 1] = {
      mesh = mesh.mesh,
      material = materialById[batch.material],
      transform = transform,
      modelNormal = Matrix3.identity(),
      center = mesh.center,
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
      fieldEffect = "warp_entrance",
    }
  end
  return items
end

function Renderer:dispose()
  self.asset = nil
end

return Renderer
