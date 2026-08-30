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
  local lifecycle = assert(definition.lifecycle, "field-effect lifecycle metadata is required: " .. response.kind)
  assert(type(lifecycle.holdFrame) == "number", "field-effect hold frame is required: " .. response.kind)
  assert(lifecycle.holdFrame >= 0 and lifecycle.holdFrame == math.floor(lifecycle.holdFrame))
  assert(lifecycle.holdUntilOwnerMoves == true, "field-effect must hold until owner moves: " .. response.kind)
  local model = assert(definition.model)
  local animations = assert(model.animations)
  assert(model.kind == "nitro-dynamic", "terrain effect requires a dynamic model")
  assert(#animations == 1, "terrain effect requires one animation")
  local animation = animations[1]
  assert(type(animation.frameCount) == "number" and lifecycle.holdFrame < animation.frameCount)
  local modelFactory = assert(self.modelFactory, "terrain effect model factory is not configured")
  local modelInstance = assert(modelFactory(response.kind, definition), "terrain effect model factory returned nil")
  local handle = modelInstance:play(animation.name, { loopMode = "once" })
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
    sourceFrame = 0,
    lifecycle = lifecycle,
    modelInstance = modelInstance,
    animationHandle = handle,
  }
end

function FieldTerrainEffectController:emitAll(responses)
  for _, response in ipairs(responses) do
    self:emit(response)
  end
end

---@param owner { fieldX: integer, fieldZ: integer, facing: string }
function FieldTerrainEffectController:updateFixed(owner)
  assert(type(owner) == "table", "terrain effect owner is required")
  assert(type(owner.fieldX) == "number" and type(owner.fieldZ) == "number", "terrain effect owner tile is required")
  assert(type(owner.facing) == "string", "terrain effect owner facing is required")
  for index = #self.instances, 1, -1 do
    local instance = self.instances[index]
    local wasIntro = instance.sourceFrame < instance.lifecycle.holdFrame
    instance.age = instance.age + 1
    if wasIntro then
      instance.modelInstance:updateFixed()
      instance.sourceFrame = math.min(instance.lifecycle.holdFrame, instance.sourceFrame + 1)
    elseif
      owner.fieldX ~= instance.fieldX
      or owner.fieldZ ~= instance.fieldZ
      or (instance.direction ~= nil and owner.facing ~= instance.direction)
    then
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

return FieldTerrainEffectController
