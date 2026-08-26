-- Presents source-derived grass effects through the engine's dynamic model
-- stack. The controller owns each mutable ModelInstance; this adapter owns
-- immutable definitions and pooled meshes/images.

local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local SceneDescriptor = require("libs.engine.src.SceneDescriptor")

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(assets, pool)
  assert(type(assets) == "table" and type(assets.effects) == "table", "terrain effect assets are required")
  assert(pool and pool.meshFor and pool.imageFor and pool.build, "field effect asset pool is required")
  local resources = {}
  pool:build(function()
    for _, kind in ipairs({ "tall_grass", "very_tall_grass" }) do
      local descriptor = assert(assets.effects[kind].model)
      local definition = ModelDefinition.fromNitroDescriptor(descriptor, { key = "field-effect:" .. kind })
      local renderMeshesById = {}
      for _, mesh in ipairs(definition.meshes) do
        local resource = pool:meshFor(mesh.geometry)
        renderMeshesById[mesh.id] = resource.mesh
        mesh.center = resource.center
      end
      resources[kind] = {
        definition = definition,
        placementOffset = assert(assets.effects[kind].placementOffset),
        renderMeshesById = renderMeshesById,
        wraps = SceneDescriptor.wrapByMaterial(descriptor.materials),
      }
    end
    return resources
  end)
  return setmetatable({ resources = resources, pool = pool }, Renderer)
end

function Renderer:newInstance(kind)
  local resource = assert(self.resources[kind], "terrain renderer is missing " .. kind)
  local instance = ModelInstance.new(resource.definition, {
    resolveImage = function(path, materialId)
      local wrap = assert(resource.wraps[materialId], "missing grass material wrap")
      return self.pool:imageFor(path, wrap.x, wrap.y)
    end,
  })
  instance.renderMeshesById = resource.renderMeshesById
  return instance
end

function Renderer:drawItems(status, runtimeMap)
  assert(status and type(status.instances) == "table", "terrain effect status instances are required")
  if #status.instances == 0 then
    return {}
  end
  assert(runtimeMap and runtimeMap.projectPhysicalPoint, "terrain effect runtime map projection is required")
  local items = {}
  for _, effect in ipairs(status.instances) do
    local point = runtimeMap:projectPhysicalPoint(effect.fieldX, effect.fieldZ, effect.cellKey, effect.sourceSurfaceId)
    local instance = assert(effect.modelInstance, "terrain effect model instance is missing")
    local resource = assert(self.resources[effect.kind], "terrain renderer is missing " .. effect.kind)
    local placementOffset = resource.placementOffset
    instance.transform = Matrix4.translate(
      point.worldX + placementOffset.x,
      point.worldY + placementOffset.y,
      point.worldZ + placementOffset.z
    )
    instance:evaluatePose()
    for _, item in ipairs(instance:drawItems(instance.renderMeshesById)) do
      item.worldSpace = true
      item.fieldEffect = effect.kind
      items[#items + 1] = item
    end
  end
  return items
end

function Renderer:dispose()
  self.resources = nil
  self.pool = nil
end

return Renderer
