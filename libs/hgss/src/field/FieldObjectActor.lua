-- One runtime map object. The decoded zone-event record stays immutable source
-- data; every value the runtime may change (facing, pose clock, visibility)
-- lives on the actor, mirroring pret/pokeheartgold's split between the event
-- record and the `MapObject` it constructs. Actors are static:
-- Semantic movement is resolved by the generated field-data contract. Pure
-- domain module.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")

---@class FieldObjectActor
---@field actorId string
---@field mapId integer
---@field objectEventId integer
---@field sourceEvent table
---@field spriteId integer
---@field fieldX integer
---@field fieldZ integer
---@field cellKey string?
---@field sourceSurfaceId integer?
---@field surfaceId integer?
---@field worldX number?
---@field worldY number?
---@field worldZ number?
---@field resident boolean
---@field initialFacing FieldDirection
---@field facing FieldDirection
---@field pose string
---@field poseTick integer
---@field private _visual table
---@field private _idlePresentation { mode: "static"|"animated", cadence: integer }
---@field private _scriptedPresentationAdvanced boolean
---@field presentationOffset { x: number, y: number } render-only action or idle display offset
---@field activeEmoteKind string? the active semantic emote (e.g. "exclamation") while an emote action is live, else nil
---@field visible boolean
---@field solid boolean
---@field movementType string
---@field interactionFacingOverride { owner: string, facing: FieldDirection, restoreFacing: FieldDirection }?
---@field pushFacingOverride fun(self: FieldObjectActor, request: { owner: string, facing: FieldDirection }): table
---@field releaseFacingOverride fun(self: FieldObjectActor, token: table)
---@field clearFacingOverride fun(self: FieldObjectActor)
---@field beginAction fun(self: FieldObjectActor, descriptor: table, owner: "script"|"autonomous")
---@field advanceAction fun(self: FieldObjectActor, progressTicks: integer, durationTicks: integer)
---@field commitAction fun(self: FieldObjectActor): table?
---@field cancelAction fun(self: FieldObjectActor)
---@field beginScriptedAction fun(self: FieldObjectActor, descriptor: table)
---@field advanceScriptedAction fun(self: FieldObjectActor, progressTicks: integer, durationTicks: integer)
---@field commitScriptedAction fun(self: FieldObjectActor): table?
---@field cancelScriptedAction fun(self: FieldObjectActor)
---@field isScriptedMoving fun(self: FieldObjectActor): boolean
---@field advancePresentationTick fun(self: FieldObjectActor)
---@field settlePresentation fun(self: FieldObjectActor)
---@field currentAction fun(self: FieldObjectActor): string?
---@field scriptedMotionState fun(self: FieldObjectActor): table?
---@field setFacing fun(self: FieldObjectActor, direction: FieldDirection)
---@field setVisible fun(self: FieldObjectActor, visible: boolean)
---@field setPosition fun(self: FieldObjectActor, position: { fieldX: integer, fieldZ: integer, worldY: number?, worldX: number?, worldZ: number?, surfaceId: integer?, cellKey: string?, sourceSurfaceId: integer?, resident: boolean })

local FieldObjectActor = {}
FieldObjectActor.__index = FieldObjectActor

local FACINGS = { north = true, south = true, west = true, east = true }

-- Walk-in-place bob amplitude, in world units (source-presentation scale,
-- applied before any host/camera transform). Two footstep bounces per cycle.
local WALK_IN_PLACE_BOB_AMPLITUDE = 0.15

local function isLocomotionAction(action)
  return action == "walk" or action == "walk_in_place" or action == "jump"
end

-- Render-only vertical bob for a walk-in-place cycle, derived deterministically
-- from the action's own fixed progress/duration ticks (never from draw
-- frequency). Two bounded bounces per cycle, zero at both boundaries.
---@param progressTicks integer
---@param durationTicks integer
---@return number
local function walkInPlaceBobOffset(progressTicks, durationTicks)
  if durationTicks <= 0 then
    return 0
  end
  local t = progressTicks / durationTicks
  return (WALK_IN_PLACE_BOB_AMPLITUDE / 2) * (1 - math.cos(4 * math.pi * t))
end

local function requireIdlePresentation(visual, idlePresentation)
  assert(type(visual) == "table", "field actor visual is required")
  assert(type(idlePresentation) == "table", "field actor idle presentation is required")
  assert(idlePresentation.mode == "static" or idlePresentation.mode == "animated", "field actor idle mode is invalid")
  assert(
    type(idlePresentation.cadence) == "number" and idlePresentation.cadence % 1 == 0,
    "field actor idle cadence is invalid"
  )
  assert(
    (idlePresentation.mode == "static" and idlePresentation.cadence == 0)
      or (idlePresentation.mode == "animated" and idlePresentation.cadence == 1),
    "field actor idle cadence does not match its mode"
  )
end

local function applyIdlePresentation(actor, advance)
  local idlePresentation = actor._idlePresentation
  if advance and idlePresentation.mode == "animated" and not actor.animationPaused then
    actor.poseTick = actor.poseTick + idlePresentation.cadence
  end
  actor.pose = "idle"
  local pose = FieldActorPose.select(actor._visual, actor.facing, "idle")
  local segment = FieldActorPose.sampleAt(pose, actor.poseTick)
  actor.presentationOffset.y = assert(segment.displayOffsetY, "field actor idle segment has no display offset")
end

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
  requireIdlePresentation(opts.visual, opts.idlePresentation)
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
    cellKey = opts.cellKey,
    sourceSurfaceId = opts.sourceSurfaceId,
    surfaceId = opts.surfaceId,
    worldX = opts.worldX,
    worldY = opts.worldY,
    worldZ = opts.worldZ,
    resident = opts.resident == true,
    initialFacing = facing,
    facing = facing,
    pose = "idle",
    poseTick = 0,
    _visual = opts.visual,
    _idlePresentation = opts.idlePresentation,
    _scriptedPresentationAdvanced = false,
    -- Render-only locomotion presentation offset (walk-in-place bob); never
    -- mutates worldX/worldY/worldZ, which stay the logical/committed anchor.
    presentationOffset = { x = 0, y = 0 },
    activeEmoteKind = nil,
    visible = true,
    -- Solid unless the source/generated event explicitly says otherwise; a
    -- zero interaction-script id is only "no A-button script" and carries no
    -- collision meaning of its own.
    solid = opts.solid ~= false,
    movementType = assert(event.movementType, "field actor movement type is required"),
    interactionFacingOverride = nil,
  }, FieldObjectActor)
end

-- Temporary facing owned by an interaction client. Only one override may be
-- live: a foreign owner must not be able to silently take or drop another's.
function FieldObjectActor:pushFacingOverride(request)
  assert(type(request) == "table" and type(request.owner) == "string", "a facing override requires an owner")
  local actorId = self.actorId --[[@as string]]
  if self.interactionFacingOverride then
    Errors.raise(
      FieldErrors.ACTOR_OVERRIDE_OWNER_MISMATCH,
      "actor " .. actorId .. " already has a facing override owned by " .. self.interactionFacingOverride.owner,
      { actorId = actorId, owner = self.interactionFacingOverride.owner, requestedBy = request.owner }
    )
  end
  local token = {
    owner = request.owner,
    facing = requireFacing(request.facing, { actorId = actorId }),
    restoreFacing = self.facing,
  }
  self.interactionFacingOverride = token
  self.facing = token.facing
  return token
end

function FieldObjectActor:releaseFacingOverride(token)
  if self.interactionFacingOverride == nil or self.interactionFacingOverride ~= token then
    local actorId = self.actorId --[[@as string]]
    Errors.raise(
      FieldErrors.ACTOR_OVERRIDE_OWNER_MISMATCH,
      "released a facing override that actor " .. actorId .. " does not hold",
      { actorId = actorId }
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

function FieldObjectActor:beginAction(descriptor, owner)
  assert(owner == "script" or owner == "autonomous", "field actor action owner is invalid")
  assert(self._motion == nil, "field actor already has an active action")
  -- descriptor: { action, direction, distance, speed, start, dest, durationTicks, name }
  -- `name` is the decoded semantic emote kind (e.g. "exclamation"); present
  -- only when action == "emote".
  local start = descriptor.start
  local dest = descriptor.dest
  self._motion = {
    owner = owner,
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
    startCellKey = start.cellKey,
    startSourceSurfaceId = start.sourceSurfaceId,
    startResident = start.resident == true,
    destFieldX = dest.fieldX,
    destFieldZ = dest.fieldZ,
    destWorldX = dest.worldX,
    destWorldY = dest.worldY,
    destWorldZ = dest.worldZ,
    destSurfaceId = dest.surfaceId,
    destCellKey = dest.cellKey,
    destSourceSurfaceId = dest.sourceSurfaceId,
    destResident = dest.resident == true,
    startPose = self.pose,
    startPoseTick = self.poseTick,
  }
  -- Every action transaction starts from a zero presentation offset; only
  -- walk_in_place's advance re-populates it while it is the active action.
  self.presentationOffset.x = 0
  self.presentationOffset.y = 0
  -- The emote indicator is active only for the action instance that carries
  -- it; every other action (including a later emote with a different kind)
  -- starts from a clean slate.
  self.activeEmoteKind = descriptor.action == "emote" and descriptor.name or nil
  -- Locomotion pose is true while a locomotion action is active. Face and
  -- gesture are explicit static presentation transitions; delays and emotes
  -- leave the current idle presentation unchanged.
  if isLocomotionAction(descriptor.action) then
    if not self.animationPaused then
      self.pose = "walk"
    end
  elseif descriptor.action == "face" or descriptor.action == "gesture" then
    self.pose = "idle"
    self.poseTick = 0
  end
end

function FieldObjectActor:beginScriptedAction(descriptor)
  self:beginAction(descriptor, "script")
end

function FieldObjectActor:advanceAction(progressTicks, durationTicks)
  local m = self._motion
  if not m then
    return
  end
  if m.owner == "script" then
    self._scriptedPresentationAdvanced = true
  end
  m.progressTicks = progressTicks
  m.durationTicks = durationTicks
  local t = durationTicks > 0 and (progressTicks / durationTicks) or 1
  if m.action == "walk" or m.action == "jump" then
    self.worldX = m.startWorldX + (m.destWorldX - m.startWorldX) * t
    self.worldZ = m.startWorldZ + (m.destWorldZ - m.startWorldZ) * t
    if m.action == "jump" then
      local h = MovementCalibration.JUMP_HEIGHTS[m.distance] or 0
      -- Parabolic arc: 4*h*t*(1-t)
      local arc = 4 * h * t * (1 - t)
      local baseY = m.startWorldY + (m.destWorldY - m.startWorldY) * t
      self.worldY = baseY + arc
    else
      self.worldY = m.startWorldY + (m.destWorldY - m.startWorldY) * t
    end
  elseif m.action == "walk_in_place" then
    -- No translation; keep at start anchor. The visible bob is a render-only
    -- offset derived deterministically from the fixed action tick, never
    -- written into worldY: terrain, camera, save, and collision all keep
    -- reading the unchanged anchor.
    self.worldX = m.startWorldX
    self.worldZ = m.startWorldZ
    self.worldY = m.startWorldY
    self.presentationOffset.y = walkInPlaceBobOffset(progressTicks, durationTicks)
  elseif m.action == "face" or m.action == "delay" or m.action == "emote" or m.action == "gesture" then
    -- No translation.
    self.worldX = m.startWorldX
    self.worldZ = m.startWorldZ
    self.worldY = m.startWorldY
  end
  -- Advance pose clock once per eligible tick for active locomotion. A delay
  -- or emote owns its tick without inheriting a prior action: its presentation
  -- comes from the visual idle profile instead.
  if not self.animationPaused then
    if isLocomotionAction(m.action) then
      local poseProgress = MovementCalibration.poseProgressTicks(m, progressTicks)
      self.pose = "walk"
      self.poseTick = m.startPoseTick + poseProgress
    end
  end
  if m.action == "delay" or m.action == "emote" then
    applyIdlePresentation(self, not self.animationPaused)
  end
  if progressTicks == durationTicks then
    if m.action == "walk" or m.action == "jump" then
      self.worldX = m.destWorldX
      self.worldY = m.destWorldY
      self.worldZ = m.destWorldZ
    end
  end
end

function FieldObjectActor:advanceScriptedAction(progressTicks, durationTicks)
  self:advanceAction(progressTicks, durationTicks)
end

function FieldObjectActor:commitAction()
  local m = self._motion
  if not m then
    return nil
  end
  local result = {
    fieldX = m.destFieldX,
    fieldZ = m.destFieldZ,
    surfaceId = m.destSurfaceId,
    cellKey = m.destCellKey,
    sourceSurfaceId = m.destSourceSurfaceId,
    worldX = m.destWorldX,
    worldY = m.destWorldY,
    worldZ = m.destWorldZ,
    resident = m.destResident,
  }
  -- The transaction settles into the visual's idle semantics; action-owned
  -- render-only state never survives the action boundary.
  self.presentationOffset.x = 0
  self.presentationOffset.y = 0
  self.activeEmoteKind = nil
  self._motion = nil
  applyIdlePresentation(self, false)
  return result
end

function FieldObjectActor:commitScriptedAction()
  return self:commitAction()
end

function FieldObjectActor:cancelAction()
  local m = self._motion
  if not m then
    return
  end
  -- Snap back to last committed logical anchor's world position.
  self.worldX = m.startWorldX
  self.worldY = m.startWorldY
  self.worldZ = m.startWorldZ
  if isLocomotionAction(m.action) then
    self.pose = m.startPose
    self.poseTick = m.startPoseTick
  end
  self.presentationOffset.x = 0
  self.presentationOffset.y = 0
  self.activeEmoteKind = nil
  self._motion = nil
  applyIdlePresentation(self, false)
end

function FieldObjectActor:cancelScriptedAction()
  self:cancelAction()
end

function FieldObjectActor:isScriptedMoving()
  return self._motion ~= nil and self._motion.owner == "script"
end

function FieldObjectActor:advancePresentationTick()
  if self._scriptedPresentationAdvanced then
    self._scriptedPresentationAdvanced = false
    return
  end
  if self._motion ~= nil or self.animationPaused then
    return
  end
  applyIdlePresentation(self, true)
end

-- Force a stable idle baseline with no residual action presentation offset.
function FieldObjectActor:settlePresentation()
  assert(self._motion == nil, "cannot settle presentation while an action is active")
  self.pose = "idle"
  self.poseTick = 0
  self.presentationOffset.x = 0
  self.presentationOffset.y = 0
  self.activeEmoteKind = nil
  applyIdlePresentation(self, false)
  self._scriptedPresentationAdvanced = false
end

-- The active semantic action kind (`walk`, `walk_in_place`, `jump`, `face`,
-- `delay`, `emote`, `gesture`), or nil while idle. This is the stable,
-- renderer/emote-facing anchor for "what is this actor currently doing"
-- without reaching into MovementTask's private plan state.
---@return string|nil
function FieldObjectActor:currentAction()
  return self._motion and self._motion.action or nil
end

function FieldObjectActor:scriptedMotionState()
  return self._motion
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
---@param position { fieldX: integer, fieldZ: integer, worldY: number?, worldX: number?, worldZ: number?, surfaceId: integer?, cellKey: string?, sourceSurfaceId: integer?, resident: boolean }
function FieldObjectActor:setPosition(position)
  self.fieldX = position.fieldX
  self.fieldZ = position.fieldZ
  self.surfaceId = position.surfaceId
  self.cellKey = position.cellKey
  self.sourceSurfaceId = position.sourceSurfaceId
  self.worldY = position.worldY
  self.worldX = position.worldX
  self.worldZ = position.worldZ
  self.resident = position.resident == true
end

return FieldObjectActor
