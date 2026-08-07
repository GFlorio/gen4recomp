-- One runtime map object. The decoded zone-event record stays immutable source
-- data; every value the runtime may change (facing, pose clock, visibility)
-- lives on the actor, mirroring pret/pokeheartgold's split between the event
-- record and the `MapObject` it constructs. Actors in this milestone are static:
-- `rawMovement` is preserved, never executed. Pure domain module.

local Errors = require("libs.rom.src.Errors")

local FieldObjectActor = {}
FieldObjectActor.__index = FieldObjectActor

local FACINGS = { north = true, south = true, west = true, east = true }

-- Identity is derived only from map and object-event identity, so it survives
-- array reordering, coordinate changes, and repeated map entry.
function FieldObjectActor.actorId(mapId, objectEventId)
  return string.format("map:%d:object:%d", mapId, objectEventId)
end

local function requireFacing(facing, context)
  if FACINGS[facing] then return facing end
  Errors.raise("ACTOR_FACING_INVALID", "unsupported actor facing " .. tostring(facing), context)
end

function FieldObjectActor.new(opts)
  assert(type(opts) == "table" and type(opts.sourceEvent) == "table",
    "FieldObjectActor requires a source event")
  local event = opts.sourceEvent
  local actorId = FieldObjectActor.actorId(opts.mapId, event.objectEventId)
  local facing = requireFacing(event.facingDirection,
    { actorId = actorId, facingDirectionRaw = event.facingDirectionRaw })

  return setmetatable({
    actorId = actorId,
    mapId = opts.mapId,
    objectEventId = event.objectEventId,
    sourceEvent = event,
    -- The runtime sprite: the zone-event value unless the creator resolved a
    -- variable sprite through the field vars (the source record stays raw).
    spriteId = opts.spriteId or event.spriteId,
    visualDef = opts.visualDef,
    fieldX = opts.fieldX,
    fieldZ = opts.fieldZ,
    surfaceId = opts.surfaceId,
    worldX = opts.worldX,
    worldY = opts.worldY,
    worldZ = opts.worldZ,
    initialFacing = facing,
    facing = facing,
    pose = "idle",
    poseTick = 0,
    visible = true,
    solid = opts.solid ~= false,
    rawMovement = event.movement,
    interactionFacingOverride = nil,
  }, FieldObjectActor)
end

-- Temporary facing owned by an interaction client. Only one override may be
-- live: a foreign owner must not be able to silently take or drop another's.
function FieldObjectActor:pushFacingOverride(request)
  assert(type(request) == "table" and type(request.owner) == "string",
    "a facing override requires an owner")
  if self.interactionFacingOverride then
    Errors.raise("ACTOR_OVERRIDE_OWNER_MISMATCH",
      "actor " .. self.actorId .. " already has a facing override owned by "
        .. self.interactionFacingOverride.owner,
      { actorId = self.actorId, owner = self.interactionFacingOverride.owner,
        requestedBy = request.owner })
  end
  local token = {
    owner = request.owner,
    facing = requireFacing(request.facing, { actorId = self.actorId }),
    restoreFacing = self.facing,
  }
  self.interactionFacingOverride = token
  self.facing = token.facing
  return token
end

function FieldObjectActor:releaseFacingOverride(token)
  if self.interactionFacingOverride == nil or self.interactionFacingOverride ~= token then
    Errors.raise("ACTOR_OVERRIDE_OWNER_MISMATCH",
      "released a facing override that actor " .. self.actorId .. " does not hold",
      { actorId = self.actorId })
  end
  self.facing = token.restoreFacing
  self.interactionFacingOverride = nil
end

-- Unwind path for hide, map exit, and state disposal: drops whatever override
-- is live without needing its token, and is safe to call when none is.
function FieldObjectActor:clearFacingOverride()
  local token = self.interactionFacingOverride
  if not token then return end
  self.facing = token.restoreFacing
  self.interactionFacingOverride = nil
end

return FieldObjectActor
