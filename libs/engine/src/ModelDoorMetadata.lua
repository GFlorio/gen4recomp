-- ModelDoorMetadata: reads the door-relevant fields off a raw generated model
-- descriptor (the plain table `cacheFs:loadLua(MapAssetCache.modelPath(...))`
-- returns) without constructing a ModelDefinition, a ModelInstance, or any
-- GPU resource. This is the one source both the headless and the
-- presentation door path read for a building's sound identity and role
-- durations, so a model's door semantics never depend on whether a live
-- ModelInstance happens to be attached. Pure domain module: no love.

local AnimationClip = require("libs.assets.src.AnimationClip")

local ModelDoorMetadata = {}

-- The door semantics of a model descriptor, or nil when the model carries no
-- door.open/door.close clip at all (the ordinary case for most building
-- models). `desc` is the plain generated record: `desc.doorSoundType`
-- (integer|nil) and `desc.animations` (an array of clip-shaped tables, each
-- optionally carrying `semanticNames`).
---@param desc table
---@return { doorSoundType: integer|nil, roles: { open: { frameCount: integer }|nil, close: { frameCount: integer }|nil } }|nil
function ModelDoorMetadata.forDescriptor(desc)
  if type(desc) ~= "table" or type(desc.animations) ~= "table" then
    return nil
  end
  local roles
  for _, clip in ipairs(desc.animations) do
    for _, semantic in ipairs(clip.semanticNames or {}) do
      local key
      if semantic == AnimationClip.ROLES.DOOR_OPEN then
        key = "open"
      elseif semantic == AnimationClip.ROLES.DOOR_CLOSE then
        key = "close"
      end
      if key then
        roles = roles or {}
        roles[key] = { frameCount = clip.frameCount }
      end
    end
  end
  if not roles then
    return nil
  end
  return { doorSoundType = desc.doorSoundType, roles = roles }
end

return ModelDoorMetadata
