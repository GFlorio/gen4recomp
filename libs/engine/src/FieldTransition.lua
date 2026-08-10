-- Owns the deterministic fade/load/swap/fade lifecycle for field warps. Map
-- projection and actor state swap through an injected commit callback only
-- while the viewport is fully black. Fallible destination preparation (load,
-- resolve, player/camera construction) runs while the source map remains the
-- authoritative current map; a failure there aborts to a coherent idle state
-- with movement unlocked and the error recorded separately from live state.
-- Map protection is owned by the runtime, never by this transition. The
-- commit step is the irreversible ownership transfer: a fault inside it is a
-- fatal programming error and propagates instead of rolling back.
--
-- Door warps run their animation and scripted player steps through the same
-- lifecycle. Source ingress overlaps the fade-out; destination opening and
-- egress overlap the fade-in; input unlocks only after the destination door
-- closes. Door choreography depends only on the map-prop and player contracts.
-- Stair warps instead hold an in-place climb on each side of the swap, play
-- the HGSS stair sound when each climb completes, and never use coordinate
-- suppression.

local WarpSystem = require("libs.engine.src.WarpSystem")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")

---@class FieldTransition
---@field loader FieldMapLoader
---@field prepare fun(resolution: table, facing: FieldDirection): table
---@field commit fun(resolution: table, facing: FieldDirection, prepared: table)
---@field resolveDestination function
---@field doorAt fun(runtimeMap: table, fieldX: integer, fieldZ: integer): table|nil
---@field playSound fun(soundId: string)?
---@field player table|nil
---@field fadeOutTicks integer
---@field fadeInTicks integer
---@field stairClimbTicks integer
---@field phase "idle"|"fade_out"|"fade_in"|string
---@field fadeAlpha number
---@field locked boolean
---@field doorActive boolean
---@field stairActive boolean
---@field stairClimbRemaining integer
---@field door table?
---@field completed table?
---@field error any?
---@field warpContext table?
---@field suppression table?
---@field prepared table?
---@field sourceMap RuntimeFieldMap?
---@field sourceWarp table?
local FieldTransition = {}
FieldTransition.__index = FieldTransition

FieldTransition.FADE_OUT_TICKS = 12
FieldTransition.FADE_IN_TICKS = 12
FieldTransition.STAIR_CLIMB_TICKS = 8
FieldTransition.STAIR_SOUND = "SEQ_SE_DP_KAIDAN2"

-- The shared phase protocol of the fade/load/swap lifecycle, referenced by
-- consumers (FieldSave, ScriptMapsService) so a rename stays in one place.
FieldTransition.PHASES = {
  idle = "idle",
  fade_out = "fade_out",
  fade_in = "fade_in",
  load_destination = "load_destination",
  swap_map = "swap_map",
  door_close = "door_close",
}

function FieldTransition.new(options)
  assert(options and options.loader, "field transition loader required")
  assert(type(options.prepare) == "function", "field transition prepare callback required")
  assert(type(options.commit) == "function", "field transition commit callback required")
  local fadeOutTicks = options.fadeOutTicks or FieldTransition.FADE_OUT_TICKS
  local fadeInTicks = options.fadeInTicks or FieldTransition.FADE_IN_TICKS
  local stairClimbTicks = options.stairClimbTicks or FieldTransition.STAIR_CLIMB_TICKS
  assert(fadeOutTicks > 0 and fadeOutTicks == math.floor(fadeOutTicks), "positive fade-out ticks required")
  assert(fadeInTicks > 0 and fadeInTicks == math.floor(fadeInTicks), "positive fade-in ticks required")
  assert(stairClimbTicks > 0 and stairClimbTicks == math.floor(stairClimbTicks), "positive stair climb ticks required")
  return setmetatable({
    loader = options.loader,
    resolveDestination = options.resolveDestination or WarpSystem.resolveDestination,
    prepare = options.prepare,
    commit = options.commit,
    doorAt = options.doorAt,
    playSound = options.playSound,
    player = options.player,
    fadeOutTicks = fadeOutTicks,
    fadeInTicks = fadeInTicks,
    stairClimbTicks = stairClimbTicks,
    phase = FieldTransition.PHASES.idle,
    locked = false,
    doorActive = false,
    stairActive = false,
    stairClimbRemaining = 0,
    fadeAlpha = 0,
  }, FieldTransition)
end

local function warpKind(sourceMap, warp)
  if not sourceMap or not sourceMap.collision or not sourceMap.coordinateOrigin then
    return nil
  end
  local behavior = TransitionTrigger.behaviorAt(sourceMap, warp.x, warp.z)
  local classification = behavior and TransitionTrigger.classify(behavior)
  return classification and classification.kind
end

local function beginSourceChoreography(self)
  local kind = warpKind(self.sourceMap, self.sourceWarp)
  if kind == "stairs" then
    self.stairActive = true
    self.stairClimbRemaining = self.stairClimbTicks
    return
  end
  if kind ~= "door" then
    return
  end
  local door = self.doorAt and self.doorAt(self.sourceMap, self.sourceWarp.x, self.sourceWarp.z)
  if door then
    door:open()
  end
  self.doorActive = true
  if self.player then
    self.player:scriptedStep(self.facing)
  end
end

local function detectDestinationDoor(self)
  if not self.doorAt or not self.resolution.destinationWarp then
    return
  end
  local warp = self.resolution.destinationWarp
  local door = self.doorAt(self.resolution.destinationMap, warp.x, warp.z)
  if door then
    self.door = door
    self.doorActive = true
  end
end

local function beginDestinationChoreography(self)
  if self.door then
    self.door:open()
  end
  if self.player then
    self.player:scriptedStep(self.facing)
  end
end

local function advanceDoorStep(self)
  if not self.doorActive or not self.player then
    return false
  end
  local walking = self.player.motion == "walking"
  if walking then
    self.player:updateFixed({})
  end
  return walking
end

local function advanceStairClimb(self)
  if not self.stairActive or self.stairClimbRemaining <= 0 then
    return
  end
  self.stairClimbRemaining = self.stairClimbRemaining - 1
  if self.stairClimbRemaining == 0 and self.playSound then
    self.playSound(FieldTransition.STAIR_SOUND)
  end
end

local function finish(self)
  self.fadeAlpha = 0
  self.phase = FieldTransition.PHASES.idle
  self.locked = false
  self.doorActive = false
  self.stairActive = false
  self.stairClimbRemaining = 0
  self.completed = {
    sourceMapId = self.sourceMap.mapId,
    destinationMapId = self.resolution.destinationMap.mapId,
    sourceWarpId = self.sourceWarp.index,
  }
  self.sourceMap, self.sourceWarp, self.resolution, self.prepared, self.door = nil, nil, nil, nil, nil
end

function FieldTransition:start(sourceMap, warp, facing)
  assert(self.phase == FieldTransition.PHASES.idle, "field transition already active")
  assert(sourceMap and warp and facing, "transition source, warp, and facing required")
  self.sourceMap = sourceMap
  self.sourceWarp = warp
  self.facing = facing
  self.progressTicks = 0
  self.resolution = nil
  self.suppression = nil
  self.prepared = nil
  self.error = nil
  self.warpContext = nil
  self.completed = nil
  self.door = nil
  self.doorActive = false
  self.stairActive = false
  self.stairClimbRemaining = 0
  self.phase = FieldTransition.PHASES.fade_out
  self.locked = true
  self.fadeAlpha = 0
  beginSourceChoreography(self)
end

-- Restore a coherent idle state after a failed preparation: unlock movement,
-- clear all source/destination state, and record the failure (with its warp
-- context) separately from live state. Map protection is untouched: the
-- transition never pins or unpins maps, so the current source map keeps its
-- runtime-owned protection.
function FieldTransition:_abort(err)
  local context
  if self.sourceMap and self.sourceWarp then
    context = {
      sourceMapId = self.sourceMap.mapId,
      sourceWarpId = self.sourceWarp.index,
      destinationMapId = self.sourceWarp.destinationMapId,
      destinationWarpId = self.sourceWarp.destinationWarpId,
    }
  end
  self.phase = FieldTransition.PHASES.idle
  self.locked = false
  self.doorActive = false
  self.stairActive = false
  self.stairClimbRemaining = 0
  self.fadeAlpha = 0
  self.progressTicks = 0
  self.completed = nil
  self.suppression = nil
  self.sourceMap, self.sourceWarp, self.resolution, self.prepared, self.door = nil, nil, nil, nil, nil
  self.error = err
  self.warpContext = context
end

function FieldTransition:updateFixed()
  if self.phase == FieldTransition.PHASES.idle then
    return false
  end
  if self.phase == FieldTransition.PHASES.fade_out then
    local moved = advanceDoorStep(self)
    advanceStairClimb(self)
    self.progressTicks = self.progressTicks + 1
    self.fadeAlpha = self.progressTicks / self.fadeOutTicks
    if self.progressTicks >= self.fadeOutTicks then
      self.fadeAlpha = 1
      self.phase = FieldTransition.PHASES.load_destination
    end
    return moved
  end
  if self.phase == FieldTransition.PHASES.load_destination then
    -- Resolution and destination preparation are the fallible warp steps:
    -- they run while the source map is still the authoritative current map,
    -- and a failure aborts with the source's ownership untouched.
    local ok, err = pcall(function()
      local result = self.resolveDestination(self.loader, self.sourceMap, self.sourceWarp)
      self.resolution = result
      detectDestinationDoor(self)
      if self.doorActive or self.stairActive then
        self.suppression = nil
      else
        self.suppression = result.suppression
      end
      self.prepared = self.prepare(result, self.facing)
    end)
    if not ok then
      return self:_abort(err)
    end
    self.phase = FieldTransition.PHASES.swap_map
    return false
  end
  if self.phase == FieldTransition.PHASES.swap_map then
    assert(self.fadeAlpha == 1, "map swap must occur while fully black")
    -- The commit is the irreversible current-map ownership transfer (actor
    -- source removal, protection transfer, pointer updates). A fault here is
    -- a fatal programming error: propagate instead of pretending to roll
    -- back partially mutated game state.
    self.commit(self.resolution, self.facing, self.prepared)
    if self.doorActive then
      beginDestinationChoreography(self)
    end
    if self.stairActive then
      self.stairClimbRemaining = self.stairClimbTicks
    end
    self.progressTicks = 0
    self.phase = FieldTransition.PHASES.fade_in
    return false
  end
  if self.phase == FieldTransition.PHASES.fade_in then
    local moved = advanceDoorStep(self)
    advanceStairClimb(self)
    self.progressTicks = self.progressTicks + 1
    self.fadeAlpha = 1 - self.progressTicks / self.fadeInTicks
    if self.progressTicks < self.fadeInTicks then
      return moved
    end
    self.fadeAlpha = 0
    if self.door then
      self.door:close()
      self.progressTicks = 0
      self.phase = FieldTransition.PHASES.door_close
      return moved
    end
    finish(self)
    return moved
  end
  assert(self.phase == FieldTransition.PHASES.door_close, "unknown field transition phase")
  if self.door:isFinished() ~= false then
    finish(self)
  end
  return false
end

function FieldTransition:consumeCompleted()
  local completed = self.completed
  self.completed = nil
  return completed
end

return FieldTransition
