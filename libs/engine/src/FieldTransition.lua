-- Owns the deterministic fade/load/swap/fade lifecycle for field warps. Map
-- projection and actor state swap through an injected commit callback only
-- while the viewport is fully black. Destination resolution and construction
-- run before the commit; a preparation failure aborts without changing live
-- map ownership. The commit is irreversible, so faults after it begins
-- propagate instead of pretending to roll back.
--
-- Door warps run the door choreography through the same lifecycle: the source
-- choreography locks input, resolves the source door (`doorAt`), starts its
-- opening animation, and begins the controlled
-- player ingress step into the doorway while the fade runs; after the black
-- swap the destination choreography resolves the destination door, opens it,
-- scripted-egresses the player from the transition anchor (the destination
-- warp coordinate, not necessarily the final tile) onto a normal floor tile,
-- closes the door, waits for the close animation, and only then unlocks
-- input -- so pressing back toward the door immediately creates a new
-- legitimate transition. Door warps skip coordinate suppression; generic
-- standing-tile warps keep it. Nothing here knows NARC ids, animation resource
-- numbers, NSBCA, or animation-list slots: doors are the mapProps doorway API
-- and the player is the field locomotion contract.
--
-- The choreography facts are explicit: sourceKind (the warp's metatile
-- classification), sourceDoor (resolved on the source map), destinationDoor
-- (resolved at load on the destination map), and needsDestinationEgress (a
-- door source always egresses; a door destination alone -- the Elm Lab exit
-- pattern -- also activates the destination choreography). A door-kind warp
-- whose door does not resolve, or a scripted step with no terrain
-- destination, is a data-contract failure and raises rather than silently
-- continuing.
--
-- Stair warps are a separate policy: the transition takes movement ownership
-- as an in-place stair climb -- HGSS holds a stair movement and never steps
-- the player off the warp tile (unk_02055BF0.c sub_0205613C) -- plays the
-- stair sound (sndseq.h SEQ_SE_DP_KAIDAN2) when the climb completes, and
-- fades; after the black swap the destination side repeats the climb on the
-- destination stair tile and unlocks at the end of the fade-in. No door
-- animation anywhere, and no coordinate suppression, so pressing the gate
-- direction on the destination stair tile re-arms the transition immediately.

local WarpSystem = require("libs.engine.src.WarpSystem")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")
local Errors = require("libs.errors.src.Errors")

---@class FieldTransition
---@field loader FieldMapLoader
---@field prepare fun(resolution: table, facing: FieldDirection): table
---@field commit fun(resolution: table, facing: FieldDirection, prepared: table)
---@field resolveDestination function
---@field doorAt fun(runtimeMap: table, fieldX: integer, fieldZ: integer): table|nil
---@field playSound fun(soundId: string)?
---@field player table|nil -- FieldPlayer, bound by the owner across the swap
---@field fadeOutTicks integer
---@field fadeInTicks integer
---@field stairClimbTicks integer
---@field phase "idle"|"fade_out"|"load_destination"|"swap_map"|"fade_in"|"door_close"|"error"
---@field fadeAlpha number
---@field locked boolean
---@field sourceKind "door"|"stairs"|nil -- the source warp's classification
---@field sourceDoor table|nil -- the resolved source door, when the source kind is a door
---@field destinationDoor table|nil -- the resolved destination door, when the destination resolves one
---@field needsDestinationEgress boolean -- the destination side runs choreography
---@field stairActive boolean
---@field stairClimbRemaining integer
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
-- The in-place climb lasts eight ticks on each side of the stair warp, the
-- same cadence as the door animations; the sound fires at its end. Tune
-- against HGSS alongside the fade cadence.
FieldTransition.STAIR_CLIMB_TICKS = 8
-- HGSS plays the stair-climb sound after the held stair movement completes,
-- before the fade (unk_02055BF0.c sub_0205613C; sndseq.h SEQ_SE_DP_KAIDAN2).
FieldTransition.STAIR_SOUND = "SEQ_SE_DP_KAIDAN2"

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
    sourceKind = nil,
    sourceDoor = nil,
    destinationDoor = nil,
    needsDestinationEgress = false,
    stairActive = false,
    stairClimbRemaining = 0,
    fadeAlpha = 0,
  }, FieldTransition)
end

-- The warp's metatile classification kind ("door" for behavior 105, "stairs"
-- for 94/95), or nil. Runtime maps always carry the permission grid and
-- coordinate origin (the loader installs both); a map without them cannot
-- classify its warps and is a data-contract failure, not a plain warp.
local function warpKind(sourceMap, warp)
  if not sourceMap or not sourceMap.collision or not sourceMap.coordinateOrigin then
    Errors.raise(
      "MAP_TRANSITION_NO_PERMISSIONS",
      "source map " .. tostring(sourceMap and sourceMap.mapId) .. " has no collision grid or coordinate origin",
      { mapId = sourceMap and sourceMap.mapId }
    )
  end
  local behavior = TransitionTrigger.behaviorAt(sourceMap, warp.x, warp.z)
  local classification = behavior and TransitionTrigger.classify(behavior)
  return classification and classification.kind
end

-- Begin the source choreography: resolve the source door at the warp tile,
-- start its opening animation, and begin the scripted ingress step into the
-- doorway. The fade runs concurrently (open, movement, and fade overlap); the
-- door finishes opening well before full black. A door-kind warp whose door
-- does not resolve, or an ingress step with no walkable destination, is a
-- data-contract failure. Stair warps instead take movement ownership as an
-- in-place climb: HGSS holds a stair movement and never steps the player off
-- the warp tile, so no door and no step here.
local function beginSourceChoreography(self)
  local kind = warpKind(self.sourceMap, self.sourceWarp)
  self.sourceKind = kind
  if kind == "door" then
    local door = self.doorAt and self.doorAt(self.sourceMap, self.sourceWarp.x, self.sourceWarp.z)
    if not door then
      Errors.raise(
        "MAP_TRANSITION_UNRESOLVED_SOURCE_DOOR",
        "door-kind warp on map "
          .. self.sourceMap.mapId
          .. " at ("
          .. self.sourceWarp.x
          .. ","
          .. self.sourceWarp.z
          .. ") resolves no door placement",
        { mapId = self.sourceMap.mapId, x = self.sourceWarp.x, z = self.sourceWarp.z }
      )
    end
    self.sourceDoor = door
    door:open()
    if self.player then
      local ok = self.player:scriptedStep(self.facing)
      if not ok then
        Errors.raise(
          "MAP_TRANSITION_INGRESS_FAILED",
          "the ingress step from the door anchor resolves no terrain destination",
          { mapId = self.sourceMap.mapId, x = self.sourceWarp.x, z = self.sourceWarp.z }
        )
      end
    end
    return
  end
  if kind == "stairs" then
    self.stairActive = true
    self.stairClimbRemaining = self.stairClimbTicks
  end
end

-- At load: resolve the destination door. A destination door alone can activate
-- the choreography (the Elm Lab exit pattern: a non-door source warp whose
-- destination tile is a door), and a source-door warp still has a destination
-- side to prepare. Resolved once here (the load phase runs a single tick),
-- opened after the swap.
local function detectDestinationDoor(self)
  if not self.doorAt or not self.resolution.destinationWarp then
    return
  end
  self.destinationDoor =
    self.doorAt(self.resolution.destinationMap, self.resolution.destinationWarp.x, self.resolution.destinationWarp.z)
end

-- After the swap: open the destination door (its opening overlaps the fade-in
-- and the egress) and begin the scripted egress step from the transition
-- anchor in the transition direction. A failed egress step is a data failure.
local function beginDestinationChoreography(self)
  if self.destinationDoor then
    self.destinationDoor:open()
  end
  if self.player then
    local ok = self.player:scriptedStep(self.facing)
    if not ok then
      Errors.raise(
        "MAP_TRANSITION_EGRESS_FAILED",
        "the egress step from the transition anchor resolves no terrain destination",
        { mapId = self.resolution.destinationMap.mapId }
      )
    end
  end
end

-- Advance the choreography's scripted step by one tick; true when the player
-- was walking at the start of the tick (the session advances the pose clock
-- on those ticks).
local function advanceDoorStep(self)
  if not self.needsDestinationEgress and not self.sourceDoor then
    return false
  end
  if not self.player then
    return false
  end
  local walking = self.player.motion == "walking"
  if walking then
    self.player:updateFixed({})
  end
  return walking
end

-- Advance the in-place stair climb by one tick. The HGSS stair sound fires
-- when the climb completes (sub_0205613C plays SEQ_SE_DP_KAIDAN2 after the
-- held movement finishes, before the fade). The climb never reports
-- locomotion: the player stays on the warp tile.
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
  self.sourceDoor = nil
  self.destinationDoor = nil
  self.needsDestinationEgress = false
  self.stairActive = false
  self.stairClimbRemaining = 0
  self.completed = {
    sourceMapId = self.sourceMap.mapId,
    destinationMapId = self.resolution.destinationMap.mapId,
    sourceWarpId = self.sourceWarp.index,
  }
  self.sourceMap, self.sourceWarp, self.resolution, self.prepared = nil, nil, nil, nil
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
  self.sourceKind = nil
  self.sourceDoor = nil
  self.destinationDoor = nil
  self.needsDestinationEgress = false
  self.stairActive = false
  self.stairClimbRemaining = 0
  self.phase = FieldTransition.PHASES.fade_out
  self.locked = true
  self.fadeAlpha = 0
  beginSourceChoreography(self)
end

-- Restore a coherent idle state after failed destination preparation. Map
-- ownership remains with the runtime throughout this path.
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
  self.sourceDoor = nil
  self.destinationDoor = nil
  self.needsDestinationEgress = false
  self.stairActive = false
  self.stairClimbRemaining = 0
  self.fadeAlpha = 0
  self.progressTicks = 0
  self.completed = nil
  self.suppression = nil
  self.sourceMap, self.sourceWarp, self.resolution, self.prepared = nil, nil, nil, nil
  self.error = err
  self.warpContext = context
end

-- Returns true when the tick advanced the choreographed player step, so the
-- session knows to advance the pose clock. The camera and the scene animation
-- clock advance on every locked tick regardless.
function FieldTransition:updateFixed()
  if self.phase == FieldTransition.PHASES.idle then
    return false
  end
  if self.phase == FieldTransition.PHASES.fade_out then
    local playerAdvanced = advanceDoorStep(self)
    advanceStairClimb(self)
    self.progressTicks = self.progressTicks + 1
    self.fadeAlpha = self.progressTicks / self.fadeOutTicks
    if self.progressTicks >= self.fadeOutTicks then
      self.fadeAlpha = 1
      self.phase = FieldTransition.PHASES.load_destination
    end
    return playerAdvanced
  end
  if self.phase == FieldTransition.PHASES.load_destination then
    local ok, err = pcall(function()
      local result = self.resolveDestination(self.loader, self.sourceMap, self.sourceWarp)
      self.resolution = result
      detectDestinationDoor(self)
      self.needsDestinationEgress = self.sourceKind == "door" or self.destinationDoor ~= nil
      -- Door and stair warps never suppress: the player egresses off the anchor
      -- (doors) or lands on the standing stair tile (stairs), so pressing back
      -- re-arms immediately. Generic standing-tile warps keep coordinate
      -- suppression.
      if self.needsDestinationEgress or self.stairActive then
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
    self.commit(self.resolution, self.facing, self.prepared)
    if self.needsDestinationEgress then
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
    local playerAdvanced = advanceDoorStep(self)
    advanceStairClimb(self)
    self.progressTicks = self.progressTicks + 1
    self.fadeAlpha = 1 - self.progressTicks / self.fadeInTicks
    if self.progressTicks < self.fadeInTicks then
      return playerAdvanced
    end
    self.fadeAlpha = 0
    if self.destinationDoor then
      self.destinationDoor:close()
      -- A static door (no animation instance) has nothing to wait for: the
      -- door_close wait phase only exists when an animation is actually
      -- closing.
      if self.destinationDoor.instance then
        self.progressTicks = 0
        self.phase = FieldTransition.PHASES.door_close
        return playerAdvanced
      end
    end
    finish(self)
    return playerAdvanced
  end
  assert(self.phase == FieldTransition.PHASES.door_close, "unknown field transition phase")
  local finished = self.destinationDoor:isFinished()
  if type(finished) ~= "boolean" then
    Errors.raise(
      "MAP_TRANSITION_DOOR_FINISH_UNRESOLVED",
      "the destination door has no closing animation state to wait for",
      {}
    )
  end
  if finished then
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
