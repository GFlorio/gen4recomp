-- Owns transient source-derived terrain-effect instances. Instances retain a
-- global field anchor and advance in fixed simulation ticks, so coverage
-- rebases only change their projected local coordinates.

---@class FieldTerrainEffectController
---@field effects table<string, table>
---@field instances table[]
---@field nextId integer
local FieldTerrainEffectController = {}
FieldTerrainEffectController.__index = FieldTerrainEffectController

function FieldTerrainEffectController.new(options)
  assert(type(options) == "table" and type(options.effects) == "table", "terrain effects are required")
  return setmetatable({
    effects = options.effects,
    modelFactory = options.modelFactory,
    instances = {},
    nextId = 0,
  }, FieldTerrainEffectController)
end

function FieldTerrainEffectController:setModelFactory(factory)
  assert(type(factory) == "function", "terrain effect model factory is required")
  assert(#self.instances == 0, "terrain effect model factory cannot change while effects are active")
  self.modelFactory = factory
end

function FieldTerrainEffectController:emit(response)
  local definition = assert(self.effects[response.kind], "missing field-effect definition: " .. response.kind)
  local modelFactory = assert(self.modelFactory, "terrain effect model factory is not configured")
  local modelInstance = assert(modelFactory(response.kind, definition), "terrain effect model factory returned nil")
  local model = assert(definition.model)
  local animations = assert(model.animations)
  assert(#animations == 1, "terrain effect requires one source animation")
  local handle = modelInstance:play(animations[1].name, { loopMode = "once" })
  self.nextId = self.nextId + 1
  self.instances[#self.instances + 1] = {
    id = self.nextId,
    kind = response.kind,
    definition = definition.definition or response.kind,
    fieldX = response.fieldX,
    fieldZ = response.fieldZ,
    cellKey = response.cellKey or response.sourceCellKey,
    sourceSurfaceId = response.sourceSurfaceId,
    sourceWorldY = response.worldY + (response.originY or 0),
    worldY = response.worldY,
    direction = response.direction,
    age = 0,
    modelInstance = modelInstance,
    animationHandle = handle,
  }
end

function FieldTerrainEffectController:emitAll(responses)
  for _, response in ipairs(responses) do
    self:emit(response)
  end
end

function FieldTerrainEffectController:updateFixed()
  for index = #self.instances, 1, -1 do
    local instance = self.instances[index]
    instance.age = instance.age + 1
    instance.modelInstance:updateFixed()
    if instance.animationHandle.player:isComplete() then
      table.remove(self.instances, index)
    end
  end
end

function FieldTerrainEffectController:clear()
  for index = #self.instances, 1, -1 do
    self.instances[index] = nil
  end
end

function FieldTerrainEffectController:status()
  local instances = {}
  for index, instance in ipairs(self.instances) do
    instances[index] = {
      id = instance.id,
      kind = instance.kind,
      definition = instance.definition,
      fieldX = instance.fieldX,
      fieldZ = instance.fieldZ,
      worldY = instance.worldY,
      cellKey = instance.cellKey,
      sourceSurfaceId = instance.sourceSurfaceId,
      sourceWorldY = instance.sourceWorldY,
      direction = instance.direction,
      age = instance.age,
      frame = instance.animationHandle.player.frameFx / 4096,
      frameCount = instance.animationHandle.player.frameCount,
      modelInstance = instance.modelInstance,
      animationComplete = instance.animationHandle.player:isComplete(),
    }
  end
  return { instances = instances }
end

function FieldTerrainEffectController:drawItems(origin)
  assert(type(origin) == "table", "terrain effect origin is required")
  local originY = origin.y or 0
  local items = {}
  for index, instance in ipairs(self.instances) do
    items[index] = {
      kind = instance.kind,
      definition = instance.definition,
      localX = instance.fieldX - origin.x,
      localZ = instance.fieldZ - origin.z,
      worldY = instance.sourceWorldY - originY,
      cellKey = instance.cellKey,
      sourceSurfaceId = instance.sourceSurfaceId,
      age = instance.age,
      fieldX = instance.fieldX,
      fieldZ = instance.fieldZ,
    }
  end
  return items
end

return FieldTerrainEffectController
