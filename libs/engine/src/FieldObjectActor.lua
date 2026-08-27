-- One runtime map object. The decoded zone-event record stays immutable source
-- data; every value the runtime may change (facing, pose clock, visibility)
-- lives on the actor, mirroring pret/pokeheartgold's split between the event
-- record and the `MapObject` it constructs. Actors are static:
-- `rawMovement` is preserved, never executed. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class FieldObjectActor
---@field actorId string
---@field mapId integer
---@field objectEventId integer
---@field sourceEvent table
---@field spriteId integer
---@field fieldX integer
---@field fieldZ integer
---@field surfaceId integer
---@field worldX number
---@field worldY number
---@field worldZ number
---@field initialFacing FieldDirection
---@field facing FieldDirection
---@field pose string
---@field poseTick integer
---@field visible boolean
---@field solid boolean
---@field rawMovement integer
---@field interactionFacingOverride { owner: string, facing: FieldDirection, restoreFacing: FieldDirection }?
---@field pushFacingOverride fun(self: FieldObjectActor, request: { owner: string, facing: FieldDirection }): table
---@field releaseFacingOverride fun(self: FieldObjectActor, token: table)
---@field clearFacingOverride fun(self: FieldObjectActor)

local FieldObjectActor = {}
FieldObjectActor.__index = FieldObjectActor

local FACINGS = { north = true, south = true, west = true, east = true }

-- Identity is derived only from map and object-event identity, so it survives
-- array reordering, coordinate changes, and repeated map entry.
function FieldObjectActor.actorId(mapId, objectEventId)
  return string.format("map:%d:object:%d", mapId, objectEventId)
end

local function requireFacing(facing, context)
  if FACINGS[facing] then
    return facing
  end
  Errors.raise(FieldErrors.ACTOR_FACING_INVALID, "unsupported actor facing " .. tostring(facing), context)
end

function FieldObjectActor.new(opts)
  assert(type(opts) == "table" and type(opts.sourceEvent) == "table", "FieldObjectActor requires a source event")
  local event = opts.sourceEvent
  local actorId = FieldObjectActor.actorId(opts.mapId, event.objectEventId)
  local facing =
    requireFacing(event.facingDirection, { actorId = actorId, facingDirectionRaw = event.facingDirectionRaw })

  return setmetatable({
    actorId = actorId,
    mapId = opts.mapId,
    objectEventId = event.objectEventId,
    sourceEvent = event,
    -- The runtime sprite: the zone-event value unless the creator resolved a
    -- variable sprite through the field vars (the source record stays raw).
    spriteId = opts.spriteId or event.spriteId,
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
    -- Solid unless the source/generated event explicitly says otherwise; a
    -- zero interaction-script id is only "no A-button script" and carries no
    -- collision meaning of its own.
    solid = opts.solid ~= false,
    rawMovement = event.movement,
    interactionFacingOverride = nil,
  }, FieldObjectActor)
end

-- Temporary facing owned by an interaction client. Only one override may be
-- live: a foreign owner must not be able to silently take or drop another's.
function FieldObjectActor:pushFacingOverride(request)
  assert(type(request) == "table" and type(request.owner) == "string", "a facing override requires an owner")
  if self.interactionFacingOverride then
    Errors.raise(
      FieldErrors.ACTOR_OVERRIDE_OWNER_MISMATCH,
      "actor " .. self.actorId .. " already has a facing override owned by " .. self.interactionFacingOverride.owner,
      { actorId = self.actorId, owner = self.interactionFacingOverride.owner, requestedBy = request.owner }
    )
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
    Errors.raise(
      FieldErrors.ACTOR_OVERRIDE_OWNER_MISMATCH,
      "released a facing override that actor " .. self.actorId .. " does not hold",
      { actorId = self.actorId }
    )
  end
  self.facing = token.restoreFacing
  self.interactionFacingOverride = nil
end

-- Unwind path for hide, map exit, and state disposal: drops whatever override
-- is live without needing its token, and is safe to call when none is.
function FieldObjectActor:clearFacingOverride()
  local token = self.interactionFacingOverride
  if not token then
    return
  end
  self.facing = token.restoreFacing
  self.interactionFacingOverride = nil
end

-- --- Scripted motion presentation --------------------------------

-- Transient scripted motion state: committed anchor + in-progress presentation.
-- Occupancy stays on committed field until commit. Draw uses presentation
-- world while motion is active.

function FieldObjectActor:beginScriptedAction(descriptor)
  -- descriptor: { action, direction, distance, speed, start, dest, durationTicks }
  local start = descriptor.start
  local dest = descriptor.dest
  self._scriptedMotion = {
    action = descriptor.action,
    direction = descriptor.direction,
    distance = descriptor.distance,
    speed = descriptor.speed,
    durationTicks = descriptor.durationTicks,
    progressTicks = 0,
    startFieldX = start.fieldX,
    startFieldZ = start.fieldZ,
    startWorldX = start.worldX,
    startWorldY = start.worldY,
    startWorldZ = start.worldZ,
    startSurfaceId = start.surfaceId,
    destFieldX = dest.fieldX,
    destFieldZ = dest.fieldZ,
    destWorldX = dest.worldX,
    destWorldY = dest.worldY,
    destWorldZ = dest.worldZ,
    destSurfaceId = dest.surfaceId,
    startPose = self.pose,
    startPoseTick = self.poseTick,
  }
  -- Enter walking pose for walk/jump; walk_in_place also walks.
  if descriptor.action == "walk" or descriptor.action == "walk_in_place" or descriptor.action == "jump" then
    if not self.animationPaused then
      self.pose = "walk"
    end
  end
end

function FieldObjectActor:advanceScriptedAction(progressTicks, durationTicks)
  local m = self._scriptedMotion
  if not m then
    return
  end
  m.progressTicks = progressTicks
  m.durationTicks = durationTicks
  local t = durationTicks > 0 and (progressTicks / durationTicks) or 1
  if m.action == "walk" or m.action == "jump" then
    self.worldX = m.startWorldX + (m.destWorldX - m.startWorldX) * t
    self.worldZ = m.startWorldZ + (m.destWorldZ - m.startWorldZ) * t
    if m.action == "jump" then
      local MovementCalibration = require("libs.engine.src.script.tasks.MovementCalibration")
      local h = MovementCalibration.JUMP_HEIGHTS[m.distance] or 0
      -- Parabolic arc: 4*h*t*(1-t)
      local arc = 4 * h * t * (1 - t)
      local baseY = m.startWorldY + (m.destWorldY - m.startWorldY) * t
      self.worldY = baseY + arc
    else
      self.worldY = m.startWorldY + (m.destWorldY - m.startWorldY) * t
    end
  elseif m.action == "walk_in_place" then
    -- No translation; keep at start anchor.
    self.worldX = m.startWorldX
    self.worldZ = m.startWorldZ
    self.worldY = m.startWorldY
  elseif m.action == "face" or m.action == "delay" or m.action == "emote" or m.action == "gesture" then
    -- No translation.
    self.worldX = m.startWorldX
    self.worldZ = m.startWorldZ
    self.worldY = m.startWorldY
  end
  -- Advance pose clock once per eligible tick while walking/jumping/walk_in_place.
  if not self.animationPaused then
    if m.action == "walk" or m.action == "walk_in_place" or m.action == "jump" then
      self.pose = "walk"
      self.poseTick = m.startPoseTick + progressTicks
    end
  end
  if progressTicks == durationTicks then
    if m.action == "walk" or m.action == "jump" then
      self.worldX = m.destWorldX
      self.worldY = m.destWorldY
      self.worldZ = m.destWorldZ
    end
  end
end

function FieldObjectActor:commitScriptedAction()
  local m = self._scriptedMotion
  if not m then
    return nil
  end
  local result = {
    fieldX = m.destFieldX,
    fieldZ = m.destFieldZ,
    surfaceId = m.destSurfaceId,
    worldX = m.destWorldX,
    worldY = m.destWorldY,
    worldZ = m.destWorldZ,
  }
  self.fieldX = m.destFieldX
  self.fieldZ = m.destFieldZ
  self.surfaceId = m.destSurfaceId
  self.worldX = m.destWorldX
  self.worldY = m.destWorldY
  self.worldZ = m.destWorldZ
  self._scriptedMotion = nil
  return result
end

function FieldObjectActor:cancelScriptedAction()
  local m = self._scriptedMotion
  if not m then
    return
  end
  -- Snap back to last committed logical anchor's world position.
  self.worldX = m.startWorldX
  self.worldY = m.startWorldY
  self.worldZ = m.startWorldZ
  if m.action == "walk" or m.action == "walk_in_place" or m.action == "jump" then
    self.pose = m.startPose
    self.poseTick = m.startPoseTick
  end
  self._scriptedMotion = nil
end

function FieldObjectActor:isScriptedMoving()
  return self._scriptedMotion ~= nil
end

function FieldObjectActor:scriptedMotionState()
  return self._scriptedMotion
end

-- --- Scripted mutation  ------------------------------------

-- Direct facing set for scripted operations (`face_player`, `face`, movement
-- tasks). Unlike the interaction override it has no owner and nothing to
-- restore; the script layer is the authority while it owns the field.
---@param direction FieldDirection
function FieldObjectActor:setFacing(direction)
  self.facing = requireFacing(direction, { actorId = self.actorId })
end

-- Scripted visibility toggle (`show_object`/`hide_object`). The flag-driven
-- existence rule stays authoritative at map entry; these are transient
-- scripted states on the live actor.
---@param visible boolean
function FieldObjectActor:setVisible(visible)
  self.visible = visible ~= false
end

-- Scripted position set: the caller (the actor manager) has already resolved
-- the destination surface and the occupancy index key for the new cell.
---@param position { fieldX: integer, fieldZ: integer, worldY: number, worldX: number, worldZ: number, surfaceId: integer }
function FieldObjectActor:setPosition(position)
  self.fieldX = position.fieldX
  self.fieldZ = position.fieldZ
  self.surfaceId = position.surfaceId
  self.worldY = position.worldY
  self.worldX = position.worldX
  self.worldZ = position.worldZ
end

return FieldObjectActor
