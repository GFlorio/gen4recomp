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
  return setmetatable({ effects = options.effects, instances = {}, nextId = 0 }, FieldTerrainEffectController)
end

function FieldTerrainEffectController:emit(response)
  local definition = assert(self.effects[response.kind], "missing field-effect definition: " .. response.kind)
  local animation = assert(definition.animation, "field-effect animation is required")
  self.nextId = self.nextId + 1
  self.instances[#self.instances + 1] = {
    id = self.nextId,
    kind = response.kind,
    definition = definition.definition or response.kind,
    fieldX = response.fieldX,
    fieldZ = response.fieldZ,
    worldY = response.worldY,
    direction = response.direction,
    age = 0,
    lifetime = assert(definition.lifetime, "field-effect lifetime is required"),
    animation = animation,
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
    if instance.age >= instance.lifetime then
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
      direction = instance.direction,
      age = instance.age,
      frame = (function()
        local elapsed = 0
        for frameIndex, frame in ipairs(instance.animation.frames) do
          elapsed = elapsed + frame.duration
          if instance.age < elapsed then
            return frameIndex
          end
        end
        return #instance.animation.frames
      end)(),
    }
  end
  return { instances = instances }
end

function FieldTerrainEffectController:drawItems(origin)
  assert(type(origin) == "table", "terrain effect origin is required")
  local items = {}
  for index, instance in ipairs(self.instances) do
    items[index] = {
      kind = instance.kind,
      definition = instance.definition,
      localX = instance.fieldX - origin.x,
      localZ = instance.fieldZ - origin.z,
      worldY = instance.worldY,
      age = instance.age,
      fieldX = instance.fieldX,
      fieldZ = instance.fieldZ,
    }
  end
  return items
end

return FieldTerrainEffectController
