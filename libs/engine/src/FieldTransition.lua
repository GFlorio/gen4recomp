-- Owns the deterministic fade/load/swap/fade lifecycle for field warps. Map
-- projection and actor state swap through an injected commit callback only
-- while the viewport is fully black. Destination resolution and construction
-- run before the commit; a preparation failure aborts without changing live
-- map ownership. The commit is irreversible, so faults after it begins
-- propagate instead of pretending to roll back.
--
-- Door warps run the door choreography through the same lifecycle, ordered per
-- HGSS (ov01_021E8744.s): the source door opens at start, the ingress step
-- begins only after the opening finished, the swap waits for the completed
-- ingress at full black, the destination door opens at the swap, the egress
-- begins only after the destination opening finished, the close begins only
-- after the egress movement finished, and input unlocks only when the close
-- and the fade-in are both finished. The fade runs orthogonally where HGSS
-- overlaps it: the source fade-out clamps at black until the ingress
-- completes (never overruns), and the fade-in ending early parks the
-- choreography in the door_close phase -- fadeAlpha stays 0, input locked --
-- until the close finishes. A static door (no animation instance) has
-- isFinished() == nil, so nothing waits on it: the egress begins at the swap
-- and the close resolves immediately. The source door never closes.
--
-- The choreography facts are explicit: sourceKind (the warp's metatile
-- classification), sourceDoor (resolved on the source map), and
-- destinationDoor (resolved at load on the destination map). The destination
-- egress predicate (a door source always egresses; a door destination alone
-- -- the Elm Lab exit pattern -- also activates the destination
-- choreography) is derived from sourceKind and destinationDoor at its read
-- sites. A door-kind warp
-- whose door does not resolve, an ingress step with no terrain destination
-- (surfacing when the choreography reaches the ingress, after the open
-- finished), or an egress step without a terrain destination, is a
-- data-contract failure and raises rather than silently continuing. Door
-- warps skip coordinate suppression; generic standing-tile warps keep it.
-- Nothing here knows NARC ids, animation resource numbers, NSBCA, or
-- animation-list slots: doors are the mapProps doorway API and the player is
-- the field locomotion contract.
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
---@field phase "idle"|"fade_out"|"load_destination"|"swap_map"|"fade_in"|"door_close"
---@field fadeAlpha number
---@field locked boolean
---@field sourceKind "door"|"stairs"|nil -- the source warp's classification
---@field sourceDoor table|nil -- the resolved source door, when the source kind is a door
---@field destinationDoor table|nil -- the resolved destination door, when the destination resolves one
---@field sourceChoreo "wait_open"|"wait_step"|"done"|nil -- the source-side door choreography state
---@field destinationChoreo "wait_open"|"wait_step"|"wait_close"|"done"|nil -- the destination-side door choreography state
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
-- HGSS plays the stair-climb sound after the held stair movement completes,
-- before the fade (unk_02055BF0.c sub_0205613C; sndseq.h SEQ_SE_DP_KAIDAN2).
-- The climb duration is the player's own movement duration
-- (FieldPlayer:beginStairClimb) -- the transition never owns a climb timer.
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
  assert(fadeOutTicks > 0 and fadeOutTicks == math.floor(fadeOutTicks), "positive fade-out ticks required")
  assert(fadeInTicks > 0 and fadeInTicks == math.floor(fadeInTicks), "positive fade-in ticks required")
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
    phase = FieldTransition.PHASES.idle,
    locked = false,
    sourceKind = nil,
    sourceDoor = nil,
    destinationDoor = nil,
    sourceChoreo = nil,
    destinationChoreo = nil,
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

-- Begin the source choreography: resolve the source door at the warp tile and
-- start its opening animation. The scripted ingress step is NOT started here
-- -- it waits for the opening to finish (advanceSourceChoreo), per HGSS, and
-- a door-kind warp whose door does not resolve is a data-contract failure.
-- Stair warps instead take movement ownership as an in-place climb: HGSS
-- holds a stair movement and never steps the player off the warp tile, so no
-- door and no step here.
local function beginSourceChoreography(self)
  local kind = warpKind(self.sourceMap, self.sourceWarp)
  self.sourceKind = kind
  if kind == "door" then
    local door = self.doorAt and self.doorAt(self.sourceMap, self.sourceWarp.x, self.sourceWarp.z)
    if not door then
      -- A scene-less runtime (headless boot: the collision-only runtime has
      -- no props, nothing to animate) has no doors to choreograph, so the
      -- warp degrades to a plain fade. A presentation scene whose door
      -- cannot resolve is a data-contract failure.
      if self.sourceMap.sceneRuntime == nil or self.sourceMap.sceneRuntime.mapProps == nil then
        self.sourceKind = nil
        return
      end
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
    self.sourceChoreo = "wait_open"
    return
  end
  if kind == "stairs" then
    -- The climb is the player's held stair movement (HGSS
    -- MapObject_SetHeldMovement), so the movement starts here and its
    -- completion -- not a transition timer -- fires the sound and gates the
    -- choreography.
    if self.player then
      assert(
        self.player.beginStairClimb ~= nil,
        "stair warps require a player with a held stair movement (FieldPlayer)"
      )
      self.player:beginStairClimb()
    end
  end
end

-- Advance the source choreography by one tick: wait_open resolves when the
-- opening finished -- a static door reports nil isFinished, so nothing waits
-- on it -- and begins the scripted ingress step; an ingress step with no
-- terrain destination is a data-contract failure raised here, when the
-- choreography reaches it, not at transition start. wait_step advances the
-- player's step and resolves done when the movement finished.
local function advanceSourceChoreo(self)
  if self.sourceChoreo == "wait_open" then
    assert(self.sourceDoor, "wait_open always carries the resolved source door")
    local finished = self.sourceDoor:isFinished()
    if finished ~= false then
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
      self.sourceChoreo = "wait_step"
    end
    return
  end
  if self.sourceChoreo == "wait_step" then
    if self.player and self.player.motion == "walking" then
      self.player:updateFixed({})
    end
    if not self.player or self.player.motion ~= "walking" then
      self.sourceChoreo = "done"
    end
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

-- After the swap: open the destination door (its opening runs inside the
-- fade-in) and start the destination choreography. The egress step begins
-- only once the opening finished (advanceDestinationChoreo) -- a static door
-- has nothing to wait for, so it begins at the swap.
local function beginDestinationChoreography(self)
  self.destinationChoreo = "wait_open"
  if self.destinationDoor then
    self.destinationDoor:open()
  end
end

-- Advance the destination choreography by one tick: wait_open resolves when
-- there is no door or its opening finished (a static door reports nil
-- isFinished, so nothing waits on it) and begins the scripted egress step; a
-- failed egress step is a data-contract failure. wait_step advances the
-- player's step, closes the destination door once the movement finished (no
-- door: nothing to close, done), and wait_close resolves when the closing
-- finished -- nil isFinished (static door) resolves immediately.
local function advanceDestinationChoreo(self)
  if self.destinationChoreo == "wait_open" then
    local finished = self.destinationDoor and self.destinationDoor:isFinished()
    if not self.destinationDoor or finished ~= false then
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
      self.destinationChoreo = "wait_step"
    end
    return
  end
  if self.destinationChoreo == "wait_step" then
    if self.player and self.player.motion == "walking" then
      self.player:updateFixed({})
    end
    if not self.player or self.player.motion ~= "walking" then
      if self.destinationDoor then
        self.destinationDoor:close()
        self.destinationChoreo = "wait_close"
      else
        self.destinationChoreo = "done"
      end
    end
    return
  end
  if self.destinationChoreo == "wait_close" and self.destinationDoor:isFinished() ~= false then
    self.destinationChoreo = "done"
  end
end

-- Run one choreography step (a begin or an advance). Before the ownership
-- commit, a failure aborts to idle and records the error. After the commit,
-- the same failure propagates as fatal because live state cannot be rolled
-- back safely.
local function runChoreo(self, fn)
  local ok, err = pcall(fn, self)
  if not ok then
    if self.phase == FieldTransition.PHASES.fade_out then
      self:_abort(err)
    end
    error(err, 0)
  end
end

-- Advance the in-place stair climb by one tick. The climb is the player's
-- held stair movement: the transition advances it like a walk, and the HGSS
-- stair sound fires when the movement completes (sub_0205613C plays
-- SEQ_SE_DP_KAIDAN2 after the held movement finishes, before the fade). The
-- climb never reports locomotion: the player stays on the warp tile.
local function advanceStairClimb(self)
  if self.sourceKind ~= "stairs" or not self.player then
    return
  end
  if self.player.motion == "climbing" then
    self.player:updateFixed({})
    if self.player.motion ~= "climbing" and self.playSound then
      self.playSound(FieldTransition.STAIR_SOUND)
    end
  end
end

local function finish(self)
  self.fadeAlpha = 0
  self.phase = FieldTransition.PHASES.idle
  self.locked = false
  self.sourceDoor = nil
  self.destinationDoor = nil
  self.sourceChoreo = nil
  self.destinationChoreo = nil
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
  self.sourceChoreo = nil
  self.destinationChoreo = nil
  self.phase = FieldTransition.PHASES.fade_out
  self.locked = true
  self.fadeAlpha = 0
  runChoreo(self, beginSourceChoreography)
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
  self.sourceChoreo = nil
  self.destinationChoreo = nil
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
    -- The locomotion report reflects the tick-start state: false during the
    -- open wait, true while the ingress step runs.
    local playerAdvanced = self.sourceChoreo ~= nil and self.player ~= nil and self.player.motion == "walking"
    advanceStairClimb(self)
    if self.sourceChoreo then
      runChoreo(self, advanceSourceChoreo)
    end
    self.progressTicks = self.progressTicks + 1
    -- The ingress finishes after the 12-tick fade, so the fade clamps at
    -- black and holds until the choreography completes -- the swap only ever
    -- happens at full black.
    self.fadeAlpha = math.min(1, self.progressTicks / self.fadeOutTicks)
    if self.fadeAlpha == 1 and (not self.sourceChoreo or self.sourceChoreo == "done") then
      self.phase = FieldTransition.PHASES.load_destination
    end
    return playerAdvanced
  end
  if self.phase == FieldTransition.PHASES.load_destination then
    local ok, err = pcall(function()
      local result = self.resolveDestination(self.loader, self.sourceMap, self.sourceWarp)
      self.resolution = result
      detectDestinationDoor(self)
      -- Door and stair warps never suppress: the player egresses off the anchor
      -- (doors) or lands on the standing stair tile (stairs), so pressing back
      -- re-arms immediately. Generic standing-tile warps keep coordinate
      -- suppression.
      if self.sourceKind == "door" or self.destinationDoor ~= nil or self.sourceKind == "stairs" then
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
    if self.sourceKind == "door" or self.destinationDoor ~= nil then
      runChoreo(self, beginDestinationChoreography)
      -- Start the destination choreography on the swap tick: an animated door
      -- holds in wait_open, a static one (nothing to wait for) steps at once.
      runChoreo(self, advanceDestinationChoreo)
    end
    if self.sourceKind == "stairs" then
      -- The destination climb begins on the rebound player at the swap,
      -- exactly like the source side: the held stair movement, not a timer.
      runChoreo(self, function(self)
        if self.player then
          assert(
            self.player.beginStairClimb ~= nil,
            "stair warps require a player with a held stair movement (FieldPlayer)"
          )
          self.player:beginStairClimb()
        end
      end)
    end
    self.progressTicks = 0
    self.phase = FieldTransition.PHASES.fade_in
    return false
  end
  if self.phase == FieldTransition.PHASES.fade_in or self.phase == FieldTransition.PHASES.door_close then
    local playerAdvanced = self.destinationChoreo ~= nil and self.player ~= nil and self.player.motion == "walking"
    advanceStairClimb(self)
    if self.destinationChoreo then
      runChoreo(self, advanceDestinationChoreo)
    end
    if self.phase == FieldTransition.PHASES.fade_in then
      self.progressTicks = self.progressTicks + 1
      self.fadeAlpha = math.max(0, 1 - self.progressTicks / self.fadeInTicks)
      if self.fadeAlpha == 0 then
        if not self.destinationChoreo or self.destinationChoreo == "done" then
          finish(self)
        else
          -- The egress/close choreography outlives the fade-in: hold black
          -- (fadeAlpha stays 0, input stays locked) in the door_close phase
          -- until the choreography finishes.
          self.phase = FieldTransition.PHASES.door_close
        end
      end
    elseif self.destinationChoreo == "done" then
      finish(self)
    end
    return playerAdvanced
  end
  assert(false, "unknown field transition phase")
end

function FieldTransition:consumeCompleted()
  local completed = self.completed
  self.completed = nil
  return completed
end

return FieldTransition
