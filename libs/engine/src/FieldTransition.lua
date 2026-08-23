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
-- choreography in the choreo_hold phase -- fadeAlpha stays 0, input locked --
-- until the close finishes. A static door (no animation instance) has
-- isFinished() == nil, so nothing waits on it: the egress begins at the swap
-- and the close resolves immediately. The source door never closes.
--
-- The choreography facts are explicit: sourceKind (the warp's trigger
-- classification, passed down from the trigger paths -- never re-read from
-- the permission grid here), sourceDoor (resolved on the source map), and
-- destinationDoor (resolved at load on the destination map). The destination
-- egress predicate (a door source always egresses; a door destination alone
-- -- the Elm Lab exit pattern -- also activates the destination
-- choreography) is derived from sourceKind and destinationDoor at its read
-- sites. Doors are a capability contract: no door resolver means no door
-- choreography at all (a headless caller states it has none, and a door-kind
-- warp degrades to a plain fade), while a supplied resolver returning no door
-- for a required door is bad data and raises. A door-kind warp
-- whose door does not resolve, an ingress step with no terrain destination
-- (surfacing when the choreography reaches the ingress, after the open
-- finished), or an egress step without a terrain destination, is a
-- data-contract failure and raises rather than silently continuing. Door
-- warps skip coordinate suppression; generic standing-tile warps keep it.
-- Nothing here knows NARC ids, animation resource numbers, NSBCA, or
-- animation-list slots: doors are the mapProps doorway API and the player is
-- the field locomotion contract.
--
-- Stair warps use the profile-owned locked source step and never use door
-- animation or coordinate compensation.

local WarpSystem = require("libs.engine.src.WarpSystem")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldTransitionProfile = require("libs.engine.src.FieldTransitionProfile")
local FieldTransitionFade = require("libs.engine.src.FieldTransitionFade")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")

---@class FieldTransition
---@field loader FieldMapLoader
---@field prepare fun(resolution: table, facing: FieldDirection): table
---@field commit fun(resolution: table, facing: FieldDirection, prepared: table)
---@field resolveDestination function
---@field doorAt fun(runtimeMap: table, fieldX: integer, fieldZ: integer): table|nil -- nil = no door choreography
---@field playSound fun(soundId: string)?
---@field stopSound fun(soundId: string)?
---@field onStart fun(sourceMap: table, trigger: table, facing: FieldDirection)? -- invoked once per transition start, before ownership changes
---@field onProfile fun(profile: integer, phase: "exit"|"enter", family: string)? -- source-specific semantic hook
---@field cameraAdjust fun(...: any)?
---@field escalatorAt fun(runtimeMap: table, fieldX: integer, fieldZ: integer): table?
---@field onPanel fun(...: any)?
---@field callbackOwner table?
---@field player table|nil -- FieldPlayer, bound by the owner across the swap
---@field phase "idle"|"fade_out"|"load_destination"|"swap_map"|"fade_in"|"choreo_hold"
---@field fadeAlpha number
---@field fade FieldTransitionFade|nil
---@field fadeStarted boolean
---@field profileId integer|nil
---@field transitionMode "fixed"|"environment"|"panel"|nil
---@field destinationFacing FieldDirection
---@field locked boolean
---@field sourceKind "door"|"stairs"|"directional"|"generic"|nil -- the trigger classification passed down
---@field sourceDoor table|nil -- the resolved source door, when the source kind is a door
---@field destinationDoor table|nil -- the resolved destination door, when the destination resolves one
---@field sourceChoreo "wait_open"|"wait_step"|"profile_motion"|"done"|nil -- the source-side choreography state
---@field destinationChoreo "wait_open"|"wait_step"|"wait_close"|"profile_motion"|"done"|nil -- the destination-side choreography state
---@field activeProfileSound string|nil
---@field ownsPlayerAnimationPause boolean
---@field completed table?
---@field error any?
---@field warpContext table?
---@field suppression table?
---@field destinationAnchorY number?
---@field prepared table?
---@field sourceMap RuntimeFieldMap?
---@field sourceWarp table?
local FieldTransition = {}
FieldTransition.__index = FieldTransition

FieldTransition.PHASES = {
  idle = "idle",
  fade_out = "fade_out",
  fade_in = "fade_in",
  load_destination = "load_destination",
  swap_map = "swap_map",
  choreo_hold = "choreo_hold",
}

function FieldTransition.new(options)
  assert(options and options.loader, "field transition loader required")
  assert(type(options.prepare) == "function", "field transition prepare callback required")
  assert(type(options.commit) == "function", "field transition commit callback required")
  return setmetatable({
    loader = options.loader,
    resolveDestination = options.resolveDestination or WarpSystem.resolveDestination,
    prepare = options.prepare,
    commit = options.commit,
    doorAt = options.doorAt,
    playSound = options.playSound,
    stopSound = options.stopSound,
    onStart = options.onStart, -- invoked once per transition start, before ownership changes
    onProfile = options.onProfile,
    cameraAdjust = options.cameraAdjust,
    escalatorAt = options.escalatorAt,
    onPanel = options.onPanel,
    callbackOwner = options.callbackOwner,
    player = options.player,
    profileId = nil,
    transitionMode = nil,
    destinationFacing = nil,
    destinationAnchorY = nil,
    phase = FieldTransition.PHASES.idle,
    locked = false,
    sourceKind = nil,
    sourceDoor = nil,
    destinationDoor = nil,
    sourceChoreo = nil,
    destinationChoreo = nil,
    fadeAlpha = 0,
    fade = nil,
    fadeStarted = false,
    profileSoundPlayed = false,
    activeProfileSound = nil,
    ownsPlayerAnimationPause = false,
    escalator = nil,
  }, FieldTransition)
end

function FieldTransition:presentationStatus()
  local fade = self.fade and self.fade:status()
    or {
      coefficient = self.fadeAlpha * 16,
      color = 0,
      direction = "out",
      completed = false,
    }
  local phase = tostring(self.phase)
  if self.sourceChoreo == "wait_open" then
    phase = "door_open"
  elseif self.sourceChoreo == "wait_step" then
    phase = "door_ingress"
  end
  local overlay
  if self.fade and fade.coefficient > 0 and (not fade.completed or fade.direction == "out") then
    local channel = fade.color == 0x7FFF and 1 or 0
    overlay = { r = channel, g = channel, b = channel, a = math.min(1, math.max(0, fade.coefficient / 16)) }
  end
  return {
    phase = phase,
    coefficient = fade.coefficient,
    color = fade.color,
    direction = fade.direction,
    completed = fade.completed,
    overlay = overlay,
    entryAction = self.profileId == FieldTransitionProfile.DOOR and "step_down" or nil,
  }
end

local function profileFamily(self)
  return assert(FieldTransitionProfile.ROUTINE_FAMILIES[self.profileId], "transition profile routine missing")
end

local function invokeProfile(self, phase)
  local family = profileFamily(self)[phase]
  if self.onProfile then
    if self.callbackOwner then
      self.onProfile(self.callbackOwner, self.profileId, phase, family)
    else
      self.onProfile(self.profileId, phase, family)
    end
  end
end

local function beginProfileMotion(self, phase)
  if self.profileId == FieldTransitionProfile.HORIZONTAL_STAIRS then
    if phase == "exit" then
      assert(self.player and type(self.player.beginTransitionStep) == "function", "stair transition step required")
      return self.player:beginTransitionStep(self.facing)
    end
    assert(self.player and type(self.player.beginTransitionHeldStair) == "function", "held stair motion required")
    return self.player:beginTransitionHeldStair(phase == "enter" and self.destinationFacing or self.facing)
  end
  if self.profileId == FieldTransitionProfile.ESCALATOR then
    assert(self.escalatorAt, "escalator prop resolver required")
    local map, x, z = self.sourceMap, self.sourceWarp.x, self.sourceWarp.z
    if phase == "enter" then
      map, x, z = self.resolution.destinationMap, self.resolution.fieldX, self.resolution.fieldZ
    end
    self.escalator = self.escalatorAt(map, x, z)
    assert(self.escalator, "escalator transition prop required")
    assert(type(self.escalator.play) == "function", "escalator prop playback required")
    assert(type(self.escalator.isFinished) == "function", "escalator prop completion required")
    assert(self.player and type(self.player.pauseTransitionAnimation) == "function", "escalator player pause required")
    assert(
      self.player and type(self.player.resumeTransitionAnimation) == "function",
      "escalator player resume required"
    )
    assert(self.player and type(self.player.beginTransitionStep) == "function", "escalator step required")
    self.escalator:play("escalator")
    self.player:pauseTransitionAnimation()
    self.ownsPlayerAnimationPause = true
    local direction = phase == "exit" and self.facing or self.destinationFacing
    local started = self.player:beginTransitionStep(direction)
    assert(started, "escalator transition step could not start")
    if phase == "exit" and not self.profileSoundPlayed and self.playSound then
      assert(self.stopSound, "escalator transition sound stop callback required")
      self.playSound(FieldTransitionProfile.ROUTINE_FAMILIES[self.profileId].exitSound)
      self.activeProfileSound = FieldTransitionProfile.ROUTINE_FAMILIES[self.profileId].exitSound
      self.profileSoundPlayed = true
    end
    return started
  end
  if self.profileId == FieldTransitionProfile.LADDER or self.profileId == FieldTransitionProfile.LADDER_DOWN then
    if phase == "exit" then
      assert(self.player, "ladder exit player required")
      local method = self.profileId == FieldTransitionProfile.LADDER and self.player.beginTransitionLadderExit
        or self.player.beginTransitionLadderDownExit
      assert(self.player and type(method) == "function", "ladder exit motion required")
      return method(self.player, self.facing)
    end
    assert(self.player and type(self.player.beginTransitionVerticalReturn) == "function", "ladder return required")
    return self.player:beginTransitionVerticalReturn(self.destinationAnchorY)
  end
  return false
end

local function advanceProfileMotion(self)
  if self.player and (self.player.motion == "transition" or self.player.motion == "walking") then
    return self.player:updateFixed({})
  end
  return false
end

local function startFade(self, direction, color)
  if self.fadeStarted and self.fade and not self.fade:status().completed then
    return
  end
  self.fade = FieldTransitionFade.new({ direction = direction, color = color })
  self.fadeStarted = true
end

local function advanceFade(self)
  if not self.fadeStarted or not self.fade then
    return
  end
  self.fade:update60()
  self.fadeAlpha = self.fade:status().coefficient / 16
end

local function stopProfileSound(self)
  if not self.activeProfileSound then
    return
  end
  assert(self.stopSound, "profile transition sound stop callback required")
  self.stopSound(self.activeProfileSound)
  self.activeProfileSound = nil
end

local function resumeOwnedPlayerAnimation(self)
  if not self.ownsPlayerAnimationPause then
    return
  end
  assert(self.player and type(self.player.resumeTransitionAnimation) == "function", "escalator player resume required")
  self.player:resumeTransitionAnimation()
  self.ownsPlayerAnimationPause = false
end

local function resetTransient(self, stopSound)
  resumeOwnedPlayerAnimation(self)
  if stopSound then
    stopProfileSound(self)
  else
    self.activeProfileSound = nil
  end
  self.fadeAlpha = 0
  self.fade = nil
  self.fadeStarted = false
  self.profileSoundPlayed = false
  self.sourceDoor = nil
  self.destinationDoor = nil
  self.sourceChoreo = nil
  self.destinationChoreo = nil
  self.destinationAnchorY = nil
  self.escalator = nil
  self.progressTicks = 0
end

-- The source fade has one sequencing owner. Source choreography only marks
-- readiness; this helper is the sole place that starts the ordinary fade and
-- any delayed profile SFX.
local function adjustHorizontalStairDestination(self, resolution)
  assert(resolution.destinationWarp, "horizontal stair destination warp required")
  local localX, localZ =
    FieldCoordinates.fieldToLocal(resolution.destinationMap, resolution.destinationWarp.x, resolution.destinationWarp.z)
  local behavior = resolution.destinationMap.collision:getLocal(localX, localZ).behavior
  local deltaX, facing
  if behavior == MetatileBehavior.BEHAVIOR.WARP_STAIRS_EAST then
    deltaX, facing = 1, "west"
  elseif behavior == MetatileBehavior.BEHAVIOR.WARP_STAIRS_WEST then
    deltaX, facing = -1, "east"
  else
    error("horizontal stair destination has no stair behavior", 0)
  end
  local fieldX = resolution.destinationWarp.x + deltaX
  local fieldZ = resolution.destinationWarp.z
  local adjustedLocalX, adjustedLocalZ = FieldCoordinates.fieldToLocal(resolution.destinationMap, fieldX, fieldZ)
  local sample = SurfaceResolver.new(resolution.destinationMap.terrain):resolve({
    localX = adjustedLocalX + FieldCoordinates.TILE_CENTER_OFFSET,
    localZ = adjustedLocalZ + FieldCoordinates.TILE_CENTER_OFFSET,
    currentY = resolution.worldY,
  })
  resolution.fieldX = fieldX
  resolution.fieldZ = fieldZ
  resolution.surfaceId = sample.surfaceId
  resolution.worldY = sample.worldY
  self.destinationFacing = facing
  self.destinationWarpX = resolution.destinationWarp.x
  self.destinationWarpZ = resolution.destinationWarp.z
end

local function adjustVerticalDestination(self, resolution)
  self.destinationAnchorY = resolution.worldY
  local offset = self.profileId == FieldTransitionProfile.LADDER and -2 or 2
  resolution.worldY = resolution.worldY + offset
end

local function selectProfile(self, sourceMap, trigger)
  local descriptor = trigger.transition
  if not descriptor then
    -- Scripted/plain callers have no source classification. They use the
    -- ordinary field-warp lifecycle, which is distinct from numeric profile
    -- 0 and therefore does not emit profile-0 exit audio.
    if trigger.kind == "door" then
      return FieldTransitionProfile.DOOR, "fixed"
    end
    if trigger.kind == "stairs" then
      return FieldTransitionProfile.HORIZONTAL_STAIRS, "fixed"
    end
    return nil, FieldTransitionProfile.MODE_PANEL
  end
  assert(
    descriptor.mode == FieldTransitionProfile.MODE_FIXED
      or descriptor.mode == FieldTransitionProfile.MODE_ENVIRONMENT
      or descriptor.mode == FieldTransitionProfile.MODE_PANEL,
    "unknown field transition mode"
  )
  if descriptor.mode == FieldTransitionProfile.MODE_FIXED then
    assert(
      FieldTransitionProfile.isValid(descriptor.profile),
      "fixed field transition profile must be an integer from 0 through 8"
    )
    return descriptor.profile, descriptor.mode
  end
  if descriptor.mode == FieldTransitionProfile.MODE_PANEL then
    return nil, descriptor.mode
  end
  local sourceEnvironment = sourceMap.fieldData and sourceMap.fieldData.transitionEnvironment
  assert(sourceEnvironment, "source transition environment required")
  assert(type(self.loader.transitionEnvironment) == "function", "field map transition metadata required")
  local destinationEnvironment = self.loader:transitionEnvironment(self.sourceWarp.destinationMapId)
  return FieldTransitionProfile.selectEnvironment(sourceEnvironment, destinationEnvironment, {
    sourceMapId = sourceMap.mapId,
    destinationMapId = self.sourceWarp.destinationMapId,
    sourceEnvironment = sourceEnvironment,
    destinationEnvironment = destinationEnvironment,
  }),
    descriptor.mode
end

-- Begin the source choreography: resolve the source door at the warp tile and
-- start its opening animation. The scripted ingress step is NOT started here
-- -- it waits for the opening to finish (advanceSourceChoreo), per HGSS, and
-- a door-kind warp whose door does not resolve is a data-contract failure.
-- The door is a capability contract: a transition without a door resolver is
-- a headless caller stating it has no door choreography, so the door warp
-- degrades to a plain fade; a supplied resolver returning no door for a
-- required door is bad data. Stair warps instead take movement ownership as
-- an in-place climb: HGSS holds a stair movement and never steps the player
-- off the warp tile, so no door and no step here. Stairs require a player
-- (production FieldRuntime always binds one): a missing player is a
-- programming fault.
local function beginSourceChoreography(self)
  local kind = self.sourceKind
  if kind == "door" then
    if not self.doorAt then
      self.sourceChoreo = "done"
      startFade(self, "out", 0)
      return
    end
    local door = self.doorAt(self.sourceMap, self.sourceWarp.x, self.sourceWarp.z)
    if not door then
      Errors.raise(
        FieldErrors.MAP_TRANSITION_UNRESOLVED_SOURCE_DOOR,
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
    local sound = door:open()
    if sound and self.playSound then
      self.playSound(sound)
    end
    self.sourceChoreo = "wait_open"
    startFade(self, "out", 0)
    return
  end
  if self.transitionMode == FieldTransitionProfile.MODE_PANEL then
    startFade(self, "out", 0)
    return
  end
  invokeProfile(self, "exit")
  local family = profileFamily(self)
  if
    family.exitSound
    and kind ~= "door"
    and self.profileId ~= FieldTransitionProfile.HORIZONTAL_STAIRS
    and self.profileId ~= FieldTransitionProfile.ESCALATOR
    and self.profileId ~= FieldTransitionProfile.LADDER
    and self.profileId ~= FieldTransitionProfile.LADDER_DOWN
    and self.playSound
  then
    self.playSound(family.exitSound)
    self.profileSoundPlayed = true
  end
  if kind ~= "door" and self.profileId ~= FieldTransitionProfile.HORIZONTAL_STAIRS then
    if
      self.profileId ~= FieldTransitionProfile.LADDER
      and self.profileId ~= FieldTransitionProfile.LADDER_DOWN
      and self.profileId ~= FieldTransitionProfile.ESCALATOR
    then
      startFade(self, "out", family.fadeColor or 0)
    end
  end
  if beginProfileMotion(self, "exit") then
    self.sourceChoreo = "profile_motion"
  end
end

-- Advance the source choreography by one tick: wait_open resolves when the
-- opening finished -- a static door reports nil isFinished, so nothing waits
-- on it -- and begins the scripted ingress step; an ingress step with no
-- terrain destination is a data-contract failure raised here, when the
-- choreography reaches it, not at transition start. wait_step advances the
-- player's step and resolves done when the movement finished.
local function advanceSourceChoreo(self)
  if self.sourceChoreo == "profile_motion" then
    advanceProfileMotion(self)
    if not self.player or (self.player.motion ~= "transition" and self.player.motion ~= "walking") then
      if self.profileId == FieldTransitionProfile.ESCALATOR then
        if not self.fadeStarted then
          local family = profileFamily(self)
          startFade(self, "out", family.fadeColor or 0)
        end
        local propFinished = not self.escalator or self.escalator:isFinished() ~= false
        if propFinished and self.fadeAlpha == 1 then
          resumeOwnedPlayerAnimation(self)
          stopProfileSound(self)
          self.sourceChoreo = "done"
        end
        return
      end
      if not self.escalator or self.escalator:isFinished() ~= false then
        self.sourceChoreo = "done"
      end
    end
    return
  end
  if self.sourceChoreo == "wait_open" then
    assert(self.sourceDoor, "wait_open always carries the resolved source door")
    local finished = self.sourceDoor:isFinished()
    if finished ~= false then
      if self.player then
        local ok = self.player:scriptedStep("north")
        if not ok then
          Errors.raise(
            FieldErrors.MAP_TRANSITION_INGRESS_FAILED,
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
  if self.sourceKind == "stairs" or not self.doorAt or not self.resolution.destinationWarp then
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
    local sound = self.destinationDoor:open()
    if sound and self.playSound and self.destinationDoor ~= self.sourceDoor then
      self.playSound(sound)
    end
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
  if self.destinationChoreo == "profile_motion" then
    advanceProfileMotion(self)
    if not self.player or (self.player.motion ~= "transition" and self.player.motion ~= "walking") then
      if self.profileId == FieldTransitionProfile.ESCALATOR then
        if self.escalator and self.escalator:isFinished() == false then
          return
        end
        resumeOwnedPlayerAnimation(self)
      end
      if self.profileId == FieldTransitionProfile.LADDER or self.profileId == FieldTransitionProfile.LADDER_DOWN then
        local direction = self.profileId == FieldTransitionProfile.LADDER and "north" or "south"
        assert(self.player and type(self.player.beginTransitionStep) == "function", "ladder destination step required")
        local ok = self.player:beginTransitionStep(direction)
        if not ok then
          Errors.raise(
            FieldErrors.MAP_TRANSITION_EGRESS_FAILED,
            "the ladder destination step resolves no terrain destination",
            { mapId = self.resolution.destinationMap.mapId, direction = direction }
          )
        end
        self.destinationChoreo = "profile_step"
      else
        self.destinationChoreo = "done"
      end
    end
    return
  end
  if self.destinationChoreo == "profile_step" then
    if self.player and self.player.motion == "walking" then
      self.player:updateFixed({})
    end
    if not self.player or self.player.motion ~= "walking" then
      self.destinationChoreo = "done"
    end
    return
  end
  if self.destinationChoreo == "wait_open" then
    local finished = self.destinationDoor and self.destinationDoor:isFinished()
    if not self.destinationDoor or finished ~= false then
      if self.player then
        local ok = self.player:scriptedStep(self.facing)
        if not ok then
          Errors.raise(
            FieldErrors.MAP_TRANSITION_EGRESS_FAILED,
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
      local animatedDoor = self.destinationDoor and self.destinationDoor:isFinished() ~= nil
      if animatedDoor then
        local sound = self.destinationDoor:close()
        if sound and self.playSound then
          self.playSound(sound)
        end
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
-- climb never reports locomotion: the player stays on the warp tile. Stair
-- warps require a player (asserted at the source begin), so one is always
-- bound here.
local function finish(self)
  resetTransient(self, true)
  self.phase = FieldTransition.PHASES.idle
  self.locked = false
  self.completed = {
    sourceMapId = self.sourceMap.mapId,
    destinationMapId = self.resolution.destinationMap.mapId,
    sourceWarpId = self.sourceWarp.index,
  }
  self.sourceMap, self.sourceWarp, self.resolution, self.prepared = nil, nil, nil, nil
end

-- Begin a transition from a warp trigger record: the classified trigger
-- ({ kind, warp }) from the session's trigger paths, or a plain-fade record
-- ({ warp = warp }) from scripted warps, which carry no classification. The
-- kind is authoritative -- the transition never re-reads the permission grid
-- to classify the warp tile.
function FieldTransition:start(sourceMap, trigger, facing)
  assert(self.phase == FieldTransition.PHASES.idle, "field transition already active")
  assert(sourceMap and trigger and trigger.warp and facing, "transition source, trigger, and facing required")
  resetTransient(self, true)
  self.sourceMap = sourceMap
  self.sourceWarp = trigger.warp
  self.sourceKind = trigger.kind
  self.transitionMode = nil
  self.destinationFacing = trigger.destinationFacing or facing
  self.profileId, self.transitionMode = selectProfile(self, sourceMap, trigger)
  self.facing = facing
  self.resolution = nil
  self.suppression = nil
  self.prepared = nil
  self.error = nil
  self.warpContext = nil
  self.completed = nil
  -- Invoke onStart callback once per transition start: this callback runs
  -- before ownership changes and can fail coherently like other pre-commit
  -- failures.
  if self.onStart then
    local ok, err = pcall(function()
      self.onStart(sourceMap, trigger, facing)
    end)
    if not ok then
      self:_abort(err)
      return
    end
  end

  self.phase = FieldTransition.PHASES.fade_out
  self.locked = true
  self.fadeAlpha = 0
  if self.transitionMode == FieldTransitionProfile.MODE_PANEL then
    if self.onPanel then
      if self.callbackOwner then
        self.onPanel(self.callbackOwner, "exit")
      else
        self.onPanel("exit")
      end
    end
  end
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
  resetTransient(self, true)
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
    if self.sourceChoreo then
      runChoreo(self, advanceSourceChoreo)
    end
    self.progressTicks = self.progressTicks + 1
    if self.sourceChoreo == "done" and not self.fadeStarted then
      local family = profileFamily(self)
      if family.exitSound and self.playSound then
        if not self.profileSoundPlayed then
          self.playSound(family.exitSound)
          self.profileSoundPlayed = true
        end
      end
      startFade(self, "out", family.fadeColor or 0)
    end
    -- The ingress finishes after the 12-tick fade, so the fade clamps at
    -- black and holds until the choreography completes -- the swap only ever
    -- happens at full black.
    if not self.fadeStarted then
      self.fadeAlpha = 0
    end
    if self.fadeAlpha == 1 and (not self.sourceChoreo or self.sourceChoreo == "done") then
      self.phase = FieldTransition.PHASES.load_destination
    end
    return playerAdvanced
  end
  if self.phase == FieldTransition.PHASES.load_destination then
    local ok, err = pcall(function()
      local result = self.resolveDestination(self.loader, self.sourceMap, self.sourceWarp)
      self.resolution = result
      if self.profileId == FieldTransitionProfile.HORIZONTAL_STAIRS then
        adjustHorizontalStairDestination(self, result)
      elseif
        self.profileId == FieldTransitionProfile.LADDER or self.profileId == FieldTransitionProfile.LADDER_DOWN
      then
        adjustVerticalDestination(self, result)
      end
      detectDestinationDoor(self)
      -- Door and stair warps never suppress: the player egresses off the anchor
      -- (doors) or lands on the standing stair tile (stairs), so pressing back
      -- re-arms immediately. Generic standing-tile warps keep coordinate
      -- suppression.
      if
        self.sourceKind == "door"
        or self.sourceKind == "directional"
        or self.destinationDoor ~= nil
        or self.sourceKind == "stairs"
      then
        self.suppression = nil
      else
        self.suppression = result.suppression
      end
      self.prepared = self.prepare(result, self.destinationFacing)
    end)
    if not ok then
      return self:_abort(err)
    end
    self.phase = FieldTransition.PHASES.swap_map
    return false
  end
  if self.phase == FieldTransition.PHASES.swap_map then
    assert(self.fadeAlpha == 1, "map swap must occur while fully black")
    self.commit(self.resolution, self.destinationFacing, self.prepared)
    if self.transitionMode == FieldTransitionProfile.MODE_PANEL then
      if self.onPanel then
        if self.callbackOwner then
          self.onPanel(self.callbackOwner, "enter")
        else
          self.onPanel("enter")
        end
      end
    elseif self.profileId then
      invokeProfile(self, "enter")
      local family = profileFamily(self)
      if family.adjustment and self.cameraAdjust then
        if self.callbackOwner then
          self.cameraAdjust(self.callbackOwner, self.profileId, family.adjustment, self.player)
        else
          self.cameraAdjust(self.profileId, family.adjustment, self.player)
        end
      end
      if beginProfileMotion(self, "enter") then
        self.destinationChoreo = "profile_motion"
      end
      startFade(self, "in", family.fadeColor or 0)
    else
      startFade(self, "in", 0)
    end
    if self.destinationChoreo == nil and (self.sourceKind == "door" or self.destinationDoor ~= nil) then
      runChoreo(self, beginDestinationChoreography)
      -- Start the destination choreography on the swap tick: an animated door
      -- holds in wait_open, a static one (nothing to wait for) steps at once.
      runChoreo(self, advanceDestinationChoreo)
    end
    self.progressTicks = 0
    self.phase = FieldTransition.PHASES.fade_in
    return false
  end
  if self.phase == FieldTransition.PHASES.fade_in or self.phase == FieldTransition.PHASES.choreo_hold then
    local playerAdvanced = self.destinationChoreo ~= nil
      and self.player ~= nil
      and (self.player.motion == "walking" or self.player.motion == "transition")
    if self.destinationChoreo then
      runChoreo(self, advanceDestinationChoreo)
    end
    if self.phase == FieldTransition.PHASES.fade_in then
      if self.fade and self.fade:status().completed then
        if not self.destinationChoreo or self.destinationChoreo == "done" then
          finish(self)
        else
          -- The egress/close choreography outlives the fade-in: hold black
          -- (fadeAlpha stays 0, input stays locked) in the choreo_hold phase
          -- until the choreography finishes.
          self.phase = FieldTransition.PHASES.choreo_hold
        end
      end
    elseif self.destinationChoreo == "done" then
      finish(self)
    end
    return playerAdvanced
  end
  assert(false, "unknown field transition phase")
end

-- Advances the presentation clock by exactly one source frame. Field
-- simulation calls updateFixed separately, so fade cadence cannot depend on
-- the 30 Hz simulation clock or on whether an audio service is composed.
function FieldTransition:updateSourceFrame()
  if self.phase == FieldTransition.PHASES.idle then
    return false
  end
  if self.fadeStarted and self.fade and not self.fade:status().completed then
    advanceFade(self)
    return true
  end
  return false
end

function FieldTransition:consumeCompleted()
  local completed = self.completed
  self.completed = nil
  return completed
end

return FieldTransition
