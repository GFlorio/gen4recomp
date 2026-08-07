-- Runs the authoritative field simulation at 60 fixed ticks per second. Player
-- movement advances before the camera so both consume the same continuous XYZ.
-- A modal dialogue owns the tick: once the fade/transition phase (which cannot
-- be active while a dialogue is open) has advanced, the session steps only the
-- dialogue and returns, so movement, warps, interactions, and actor pose
-- clocks freeze until the dialogue closes (spec section 11.3).

local WarpSystem = require("libs.engine.src.WarpSystem")

---@class FieldSession
---@field versionId string
---@field currentMap RuntimeFieldMap
---@field actor table
---@field player table
---@field camera table
---@field transition table?
---@field actors table?
---@field playerVisual table?
---@field dialogue FieldDialogueController?
---@field input FieldInput?
---@field coverage fun(session: FieldSession)?
---@field trace fun(record: table)?
---@field tick integer
---@field accumulator number
---@field discardedTicks integer
local FieldSession = {}
FieldSession.__index = FieldSession

FieldSession.FIXED_DT = 1 / 60
FieldSession.MAX_CATCH_UP_TICKS = 5

---@param options table
---@return FieldSession
function FieldSession.new(options)
  assert(options and options.versionId and options.currentMap, "field session identity required")
  assert(options.actor and options.camera, "field session actor and camera required")
  return setmetatable({
    versionId = options.versionId,
    currentMap = options.currentMap,
    actor = options.actor,
    player = options.player or options.actor,
    camera = options.camera,
    transition = options.transition,
    actors = options.actors,
    playerVisual = options.playerVisual,
    dialogue = options.dialogue,
    input = options.input,
    coverage = options.coverage,
    trace = options.trace,
    tick = 0,
    accumulator = 0,
    discardedTicks = 0,
  }, FieldSession)
end

function FieldSession:actorTarget()
  return { x = self.actor.worldX, y = self.actor.worldY, z = self.actor.worldZ }
end

function FieldSession:_recordTick()
  self.tick = self.tick + 1
  if self.trace then self.trace(self:traceRecord()) end
end

function FieldSession:updateFixed(inputSnapshot)
  inputSnapshot = inputSnapshot or (self.input and self.input:snapshot()) or {}
  if self.transition and self.transition.updateFixed then
    self.transition:updateFixed(inputSnapshot)
    -- Keep the just-arrived tile stable until the application consumes the
    -- completion event and autosaves it, even when movement remains held.
    if self.transition.completed then
      if self.input and self.input.clearEdges then self.input:clearEdges() end
      self:_recordTick()
      return
    end
    if self.transition.locked then
      self:_recordTick()
      return
    end
  end

  -- Modal ownership: while a dialogue is open the world freezes -- no queued
  -- visibility changes, no facing-warp check, no movement, no warp commit, no
  -- pose clocks, no camera motion. Only the dialogue reads this tick's input.
  if self.dialogue and self.dialogue:isModal() then
    self.dialogue:step(inputSnapshot)
    self:_recordTick()
    return
  end

  if self.transition and self.transition.suppression then
    self.transition.suppression = WarpSystem.updateSuppression(self.transition.suppression,
      self.currentMap.mapId, self.player.fieldX, self.player.fieldZ)
  end

  -- Queued visibility changes land before anything reads occupancy or starts a
  -- move, so collision and the draw list never disagree within a tick.
  if self.actors then self.actors:step(self.tick + 1) end

  local direction = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  if self.transition and self.transition.start and self.player.motion == "idle" and direction then
    local facingWarp = WarpSystem.findBlockedFacing(self.currentMap,
      self.player.fieldX, self.player.fieldZ, direction)
    if facingWarp and not WarpSystem.isSuppressed(self.transition.suppression,
      self.currentMap.mapId, facingWarp.x, facingWarp.z) then
      self.player.facing = direction
      self.transition:start(self.currentMap, facingWarp, direction)
      self:_recordTick()
      return
    end
  end

  local stepCompleted = false
  if self.player.updateFixed then stepCompleted = self.player:updateFixed(inputSnapshot) == true end
  if stepCompleted and self.transition and self.transition.start then
    local standingWarp = WarpSystem.findAt(self.currentMap, self.player.fieldX, self.player.fieldZ)
    if standingWarp and not WarpSystem.isSuppressed(self.transition.suppression,
      self.currentMap.mapId, self.player.fieldX, self.player.fieldZ) then
      self.transition:start(self.currentMap, standingWarp, self.player.facing)
    end
  end
  -- Pose clocks advance only on a tick that could change the world, so a fade or
  -- a locked transition freezes animation instead of walking it in place.
  if self.playerVisual then self.playerVisual:updateFixed() end
  self.camera:updateFixed(self:actorTarget())
  if self.coverage then self.coverage(self) end
  self:_recordTick()
end

function FieldSession:traceRecord()
  local record = {
    tick = self.tick,
    mapId = self.currentMap.mapId,
    fieldX = self.player.fieldX,
    fieldZ = self.player.fieldZ,
    worldY = self.player.worldY,
    surfaceId = self.player.surfaceId,
    facing = self.player.facing,
    motion = self.player.motion,
    transitionState = self.transition and self.transition.phase or nil,
    cameraType = self.currentMap.cameraType,
    cameraSourceY = self.camera.cameraSourceY,
    cameraAppliedY = self.camera.cameraAppliedY,
  }
  if self.player.status then
    local status = self.player:status()
    record.localX, record.localZ = status.localX, status.localZ
    record.surfaceNormal = status.surfaceNormal
    record.slopeClass = status.slopeClass
    record.destinationSurfaceId = status.destinationSurfaceId
  end
  return record
end

function FieldSession:update(dt, inputSnapshot)
  assert(type(dt) == "number" and dt >= 0, "non-negative update dt required")
  self.accumulator = self.accumulator + dt
  local executed = 0
  while self.accumulator + 1e-12 >= FieldSession.FIXED_DT
    and executed < FieldSession.MAX_CATCH_UP_TICKS do
    self.accumulator = self.accumulator - FieldSession.FIXED_DT
    self:updateFixed(inputSnapshot)
    executed = executed + 1
  end
  if self.accumulator + 1e-12 >= FieldSession.FIXED_DT then
    local discarded = math.floor((self.accumulator + 1e-12) / FieldSession.FIXED_DT)
    self.discardedTicks = self.discardedTicks + discarded
    self.accumulator = self.accumulator - discarded * FieldSession.FIXED_DT
  end
  return executed
end

function FieldSession:renderAlpha()
  return self.accumulator / FieldSession.FIXED_DT
end

return FieldSession
