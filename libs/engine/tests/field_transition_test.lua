-- FieldTransition tests freeze the project fade cadence, black-only swap,
-- input lock, completion event, and arrival suppression. Map protection is
-- owned by the runtime: the transition never pins or unpins maps, aborting a
-- failed transition never touches loader protection, and a commit fault
-- after the black-frame ownership transfer begins is fatal (no transition
-- rollback).

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.engine.src.FieldTransition")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

-- A loader whose protection record must stay empty: the transition is not a
-- protection owner, so no lifecycle path may call protectMap.
local function recordingLoader()
  local protections = {}
  return {
    protections = protections,
    protectMap = function(_, mapId, protected)
      protections[#protections + 1] = { mapId, protected }
    end,
  }
end

local function destination()
  return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
end

function T.fades_loads_swaps_while_black_and_completes()
  local source = { mapId = 61 }
  local destination = { mapId = 60 }
  local warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 }
  local protections, prepares, commits = {}, {}, {}
  local loader = {
    protectMap = function(_, mapId, protected)
      protections[#protections + 1] = { mapId, protected }
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 2,
    fadeInTicks = 2,
    resolveDestination = function()
      return {
        destinationMap = destination,
        fieldX = 684,
        fieldZ = 393,
        surfaceId = 0,
        worldY = 0,
        suppression = { mapId = 60, fieldX = 684, fieldZ = 393 },
      }
    end,
    prepare = function(result, facing)
      prepares[#prepares + 1] = { result = result, facing = facing }
      return { payload = result.destinationMap }
    end,
    commit = function(result, facing, prepared)
      commits[#commits + 1] = { result = result, facing = facing, prepared = prepared }
    end,
  })

  transition:start(source, warp, "south")
  Assert.equal(transition.phase, "fade_out")
  Assert.isTrue(transition.locked)
  transition:updateFixed()
  Assert.equal(transition.fadeAlpha, 0.5)
  transition:updateFixed()
  Assert.equal(transition.phase, "load_destination")
  Assert.equal(transition.fadeAlpha, 1)
  transition:updateFixed()
  Assert.equal(transition.phase, "swap_map")
  Assert.equal(#prepares, 1)
  Assert.equal(prepares[1].facing, "south")
  Assert.equal(#commits, 0)
  transition:updateFixed()
  Assert.equal(transition.phase, "fade_in")
  Assert.equal(transition.fadeAlpha, 1)
  Assert.equal(#commits, 1)
  Assert.equal(commits[1].facing, "south")
  Assert.equal(commits[1].prepared.payload.mapId, 60)
  transition:updateFixed()
  Assert.equal(transition.fadeAlpha, 0.5)
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(transition.fadeAlpha, 0)
  Assert.deepEqual(transition:consumeCompleted(), {
    sourceMapId = 61,
    destinationMapId = 60,
    sourceWarpId = 0,
  })
  Assert.isNil(transition:consumeCompleted())
  Assert.deepEqual(protections, {})
end

-- The default resolver is WarpSystem.resolveDestination: a transition built
-- without a custom resolver must resolve a scripted direct warp record (the
-- production wiring FieldRuntime relies on) through the moved branch. The
-- loader needs no protectMap surface: protection is not transition-owned.
function T.default_resolver_handles_direct_warp_records()
  local destination = {
    mapId = 60,
    coordinateOrigin = { x = 672, z = 384 },
    fieldData = { events = { warps = {} } },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
  local loader = {
    load = function()
      return destination
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 1,
    fadeInTicks = 1,
    prepare = function() end,
    commit = function() end,
  })
  transition:start(
    { mapId = 61 },
    { index = 0, destinationMapId = 60, destinationWarpId = 0, x = 688, z = 392, direct = true },
    "south"
  )
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "swap_map")
  Assert.equal(transition.resolution.fieldX, 688)
  Assert.equal(transition.resolution.fieldZ, 392)
  Assert.equal(transition.resolution.destinationWarp.direct, true)
  Assert.deepEqual(transition.suppression, { mapId = 60, fieldX = 688, fieldZ = 392 })
end

-- A failed resolution aborts to a coherent idle state: unlocked, source
-- state cleared, and the error recorded separately. Loader protection is
-- never touched, so an aborted transition can never release the current
-- source map's runtime-owned protection. A later start must run a full
-- transition to completion.
function T.resolve_failure_aborts_and_a_second_transition_succeeds()
  local loader = recordingLoader()
  local failures = 1
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 1,
    fadeInTicks = 1,
    resolveDestination = function()
      if failures > 0 then
        failures = failures - 1
        error("resolve failed", 0)
      end
      return destination()
    end,
    prepare = function() end,
    commit = function() end,
  })

  transition:start({ mapId = 61 }, { index = 0, destinationMapId = 60, destinationWarpId = 0 }, "south")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(transition.fadeAlpha, 0)
  Assert.equal(tostring(transition.error), "resolve failed")
  Assert.isNil(transition.sourceMap)
  Assert.isNil(transition.sourceWarp)
  Assert.isNil(transition.resolution)
  Assert.isNil(transition:consumeCompleted())
  Assert.deepEqual(loader.protections, {}, "an aborted transition never touches map protection")

  transition:start({ mapId = 61 }, { index = 0, destinationMapId = 60, destinationWarpId = 0 }, "south")
  transition:updateFixed()
  transition:updateFixed()
  transition:updateFixed()
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.isNil(transition.error)
  Assert.deepEqual(transition:consumeCompleted(), {
    sourceMapId = 61,
    destinationMapId = 60,
    sourceWarpId = 0,
  })
  Assert.deepEqual(loader.protections, {})
end

-- A failed prepare aborts the same way: destination player/camera
-- construction is fallible preparation that must run while the source map
-- remains the authoritative current map, so a failure leaves source
-- protection untouched and records the error.
function T.prepare_failure_aborts_with_source_protection_untouched()
  local loader = recordingLoader()
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 1,
    fadeInTicks = 1,
    resolveDestination = destination,
    prepare = function()
      error("prepare failed", 0)
    end,
    commit = function() end,
  })
  transition:start({ mapId = 61 }, { index = 0, destinationMapId = 60, destinationWarpId = 0 }, "south")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(tostring(transition.error), "prepare failed")
  Assert.isNil(transition.resolution)
  Assert.deepEqual(loader.protections, {})
end

-- A fault inside the commit (the irreversible black-frame ownership
-- transfer) is a fatal programming error: it propagates out of updateFixed
-- and the transition does not pretend to roll back arbitrary partially
-- mutated game state by aborting to idle.
function T.commit_fault_propagates_as_fatal()
  local loader = recordingLoader()
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 1,
    fadeInTicks = 1,
    resolveDestination = destination,
    prepare = function() end,
    commit = function()
      error("commit failed", 0)
    end,
  })
  transition:start({ mapId = 61 }, { index = 0, destinationMapId = 60, destinationWarpId = 0 }, "south")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "swap_map")
  local ok, err = pcall(transition.updateFixed, transition)
  Assert.isFalse(ok)
  Assert.equal(tostring(err), "commit failed")
  Assert.equal(transition.phase, "swap_map")
  Assert.isNil(transition.error, "commit faults are not transition errors")
  Assert.deepEqual(loader.protections, {})
end

-- The failed-warp context is recorded with the error: the destination and
-- source ids survive the abort for diagnostics, separate from live state.
function T.abort_records_the_failed_warp_context()
  local loader = recordingLoader()
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 1,
    fadeInTicks = 1,
    resolveDestination = function()
      error("resolve failed", 0)
    end,
    prepare = function() end,
    commit = function() end,
  })
  transition:start({ mapId = 61 }, { index = 4, destinationMapId = 60, destinationWarpId = 2 }, "south")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.deepEqual(transition.warpContext, {
    sourceMapId = 61,
    sourceWarpId = 4,
    destinationMapId = 60,
    destinationWarpId = 2,
  })
end
-- ---- door source/destination choreography ----

-- A door handle stub with the MapDoor contract: open/close no-op for static
-- doors (isFinished nil when nothing plays).
local function doorStub(animated)
  local door = {
    animated = animated ~= false,
    opened = 0,
    closed = 0,
    open = function(self)
      self.opened = self.opened + 1
      self.finished = false
    end,
    close = function(self)
      self.closed = self.closed + 1
      self.finished = false
    end,
    isFinished = function(self)
      if not self.animated then
        return nil
      end
      return self.finished
    end,
  }
  return door
end

-- A player stub with the locomotion contract the choreography drives:
-- scriptedStep begins a scripted walk, updateFixed advances it.
local function stubPlayer()
  local p = {
    motion = "idle",
    facing = "south",
    steps = {},
    updates = 0,
    scriptedStep = function(self, direction)
      self.steps[#self.steps + 1] = direction
      self.motion = "walking"
      self.facing = direction
      return true
    end,
    updateFixed = function(self)
      self.updates = self.updates + 1
      self.motion = "idle"
      return true
    end,
  }
  return p
end

local BEHAVIOR_DOOR = 105
local BEHAVIOR_ENTRANCE_SOUTH = 101
local BEHAVIOR_STAIRS_WEST = 95

-- The source map stub classifies warp-tile behaviors for the transition's
-- door-kind detection; the plain fades_loads_swaps test keeps a bare map so
-- classification must be guarded on permission coverage presence.
local function sourceMap(behavior)
  return {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      getLocal = function(_, x, z)
        if x == 4 and z == 14 then
          return { behavior = behavior }
        end
        return { behavior = 0 }
      end,
      isBlockedLocal = function()
        return false
      end,
    },
  }
end

-- A choreography transition over stub maps: the source map's warp tile (4,14)
-- classifies with `behavior`; `opts.doorAt` resolves source/destination doors
-- (nil for stair warps, which carry no doors); playSound records the stair
-- sound; the resolution carries a coordinate suppression token. The default
-- test fade is two ticks, so the helper's default stair climb is two ticks
-- too -- the climb must complete inside the fade.
local function transitionFixture(opts)
  opts = opts or {}
  local source = sourceMap(opts.behavior or BEHAVIOR_DOOR)
  local destination = { mapId = 60 }
  local loader = {
    load = function()
      return destination
    end,
    protectMap = function() end,
    protectCells = function() end,
  }
  local swaps = {}
  local sounds = {}
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 2,
    fadeInTicks = 2,
    stairClimbTicks = opts.stairClimbTicks or 2,
    doorAt = opts.doorAt,
    playSound = function(soundId)
      sounds[#sounds + 1] = soundId
    end,
    resolveDestination = function()
      return {
        destinationMap = destination,
        destinationWarp = { x = 684, z = 393 },
        fieldX = 684,
        fieldZ = 393,
        surfaceId = 0,
        worldY = 0,
        suppression = { mapId = 60, fieldX = 684, fieldZ = 393 },
      }
    end,
    prepare = function(result)
      return result
    end,
    commit = function(result, facing)
      swaps[#swaps + 1] = { result = result, facing = facing }
    end,
  })
  if opts.player then
    transition.player = opts.player
  end
  return transition, source, destination, swaps, sounds
end

local DOOR_WARP = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }

function T.door_source_opens_and_ingresses_before_the_black_swap()
  local sourceDoor = doorStub()
  local player = stubPlayer()
  local transition
  local source
  local swaps
  transition, source, _, swaps = transitionFixture({
    doorAt = function(runtimeMap, x, z)
      if runtimeMap == source then
        return sourceDoor
      end
      return nil
    end,
    player = player,
  })
  transition:start(source, DOOR_WARP, "south")
  Assert.equal(transition.phase, "fade_out")
  Assert.isTrue(transition.locked)
  Assert.equal(sourceDoor.opened, 1, "the source door opens at transition start")
  Assert.deepEqual(player.steps, { "south" }, "the ingress step begins immediately")
  Assert.equal(player.motion, "walking")
  Assert.isTrue(transition.doorActive)

  local moved = transition:updateFixed()
  Assert.isTrue(moved, "a mid-step tick reports locomotion")
  Assert.equal(player.updates, 1)
  Assert.equal(transition.fadeAlpha, 0.5)
  transition:updateFixed()
  Assert.equal(transition.phase, "load_destination")
  Assert.equal(transition.fadeAlpha, 1)
  Assert.equal(#swaps, 0, "no swap before full black")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "fade_in")
  Assert.equal(#swaps, 1)
  Assert.equal(swaps[1].facing, "south")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.isFalse(transition.doorActive)
  Assert.equal(sourceDoor.closed, 0, "the source door never closes; the map is discarded")
  Assert.deepEqual(
    player.steps,
    { "south", "south" },
    "the destination egress walks off the anchor even without a door"
  )
  Assert.equal(player.updates, 2)
end

function T.destination_door_opens_egresses_closes_and_waits_for_completion()
  local sourceDoor = doorStub()
  local destinationDoor = doorStub()
  local player = stubPlayer()
  local transition
  local source
  transition, source = transitionFixture({
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return destinationDoor
    end,
    player = player,
  })
  transition:start(source, DOOR_WARP, "south")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "load_destination")
  transition:updateFixed()
  Assert.equal(transition.phase, "swap_map")
  transition:updateFixed()
  Assert.equal(transition.phase, "fade_in")
  Assert.equal(destinationDoor.opened, 1, "the destination door opens after the swap")
  Assert.deepEqual(player.steps, { "south", "south" }, "the egress step follows the transition direction")
  Assert.equal(player.motion, "walking")
  transition:updateFixed()
  Assert.equal(player.updates, 2, "the egress step advances with the fade-in")
  transition:updateFixed()
  Assert.equal(transition.phase, "door_close")
  Assert.isTrue(transition.locked, "input stays locked while the door closes")
  Assert.equal(destinationDoor.closed, 1, "the destination door closes after the fade-in")

  transition:updateFixed()
  Assert.equal(transition.phase, "door_close", "the close completion gates the unlock")
  destinationDoor.finished = true
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.notNil(transition:consumeCompleted())
end

function T.destination_door_alone_activates_the_choreography()
  -- The Elm Lab exit pattern: the source warp tile is an entrance (101), not
  -- a door, but the destination tile resolves a door -- the choreography
  -- activates at load and the destination sequence still runs.
  local destinationDoor = doorStub()
  local player = stubPlayer()
  local transition
  local source
  transition, source = transitionFixture({
    behavior = BEHAVIOR_ENTRANCE_SOUTH,
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return nil
      end
      return destinationDoor
    end,
    player = player,
  })
  transition:start(source, DOOR_WARP, "south")
  Assert.isFalse(transition.doorActive, "no door on the source side")
  Assert.equal(#player.steps, 0, "no ingress step without a source door")
  transition:updateFixed()
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "swap_map")
  Assert.equal(destinationDoor.opened, 0, "the destination door opens only after the swap")
  transition:updateFixed()
  Assert.equal(transition.phase, "fade_in")
  Assert.equal(destinationDoor.opened, 1)
  Assert.deepEqual(player.steps, { "south" }, "the egress step resolves the blocked anchor")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "door_close")
  Assert.equal(destinationDoor.closed, 1)
  destinationDoor.finished = true
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
end

function T.static_destination_door_does_not_block_the_unlock()
  local staticDoor = doorStub(false)
  local transition
  local source
  transition, source = transitionFixture({
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return nil
      end
      return staticDoor
    end,
    player = stubPlayer(),
  })
  transition:start(source, DOOR_WARP, "south")
  for _ = 1, 6 do
    transition:updateFixed()
  end
  Assert.equal(transition.phase, "door_close")
  Assert.equal(staticDoor.closed, 1)
  transition:updateFixed()
  Assert.equal(transition.phase, "idle", "a static door (no animation) has nothing to wait for")
  Assert.isFalse(transition.locked)
end

function T.door_warps_skip_coordinate_suppression()
  local transition, source = transitionFixture({ player = stubPlayer() })
  transition:start(source, DOOR_WARP, "south")
  for _ = 1, 4 do
    transition:updateFixed()
  end
  Assert.isNil(transition.suppression, "door warps re-arm immediately after egress")
end

function T.generic_warps_keep_coordinate_suppression()
  local transition, source = transitionFixture({ behavior = 110, player = stubPlayer() })
  transition:start(source, { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }, "north")
  for _ = 1, 4 do
    transition:updateFixed()
  end
  Assert.deepEqual(transition.suppression, { mapId = 60, fieldX = 684, fieldZ = 393 })
end

function T.plain_warps_never_drive_the_player()
  local player = stubPlayer()
  local transition, source = transitionFixture({ behavior = 110, player = player })
  transition:start(source, { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }, "north")
  for _ = 1, 6 do
    Assert.isFalse(transition:updateFixed(), "a plain fade never reports locomotion")
  end
  Assert.equal(#player.steps, 0)
  Assert.equal(player.updates, 0)
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.doorActive)
end

function T.ingress_skipped_when_the_step_cannot_resolve()
  -- A door warp whose ingress step fails (no walkable surface) still fades,
  -- swaps, and completes -- movement is opportunistic, not blocking.
  local transition, source = transitionFixture({
    doorAt = function()
      return nil
    end,
    player = {
      motion = "idle",
      facing = "south",
      scriptedStep = function()
        return false
      end,
    },
  })
  transition:start(source, DOOR_WARP, "south")
  for _ = 1, 6 do
    transition:updateFixed()
  end
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.isFalse(transition.doorActive)
end

-- ---- stair choreography ----

function T.stair_source_climbs_in_place_without_door_or_step()
  -- Stairs are a separate policy: the transition takes movement ownership as
  -- an in-place climb -- the tile ahead is the blocked stair wall, and HGSS
  -- holds a stair movement rather than stepping the player.
  local player = stubPlayer()
  local transition
  local source
  local sounds
  transition, source, _, _, sounds = transitionFixture({ behavior = BEHAVIOR_STAIRS_WEST, player = player })
  transition:start(source, DOOR_WARP, "west")
  Assert.isTrue(transition.stairActive, "the stair warp activates the stair choreography")
  Assert.isFalse(transition.doorActive, "stairs never activate the door choreography")
  Assert.deepEqual(player.steps, {}, "the stair climb never steps the player")
  Assert.equal(player.updates, 0, "the player keeps standing on the warp tile")
  Assert.equal(#sounds, 0, "the sound fires when the climb completes, not at start")

  local moved = transition:updateFixed()
  Assert.isFalse(moved, "the in-place climb reports no locomotion")
  Assert.equal(transition.fadeAlpha, 0.5)
  Assert.equal(#sounds, 0, "the climb needs its full duration before the sound")
  Assert.equal(player.updates, 0)

  transition:updateFixed()
  Assert.equal(transition.phase, "load_destination")
  Assert.equal(transition.fadeAlpha, 1)
  Assert.equal(#sounds, 1, "the stair sound fires when the climb completes")
  Assert.equal(sounds[1], FieldTransition.STAIR_SOUND, "the HGSS stair-climb sound id")
end

function T.stair_transition_sounds_twice_and_finishes_at_fade_in_end()
  -- One climb per side (source + destination); the swap stays black-only;
  -- stairs skip coordinate suppression; input unlocks right after the
  -- destination fade-in -- there is no door to close.
  local player = stubPlayer()
  local transition
  local source
  local swaps
  local sounds
  transition, source, _, swaps, sounds = transitionFixture({ behavior = BEHAVIOR_STAIRS_WEST, player = player })
  transition:start(source, DOOR_WARP, "west")
  for _ = 1, 6 do
    transition:updateFixed()
  end
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.isFalse(transition.stairActive)
  Assert.isFalse(transition.doorActive)
  Assert.equal(#swaps, 1, "the map swaps once")
  Assert.equal(#sounds, 2, "one stair sound per side: the source climb and the destination climb")
  Assert.equal(sounds[1], FieldTransition.STAIR_SOUND)
  Assert.equal(sounds[2], FieldTransition.STAIR_SOUND)
  Assert.deepEqual(player.steps, {}, "stairs never drive scripted steps")
  Assert.equal(transition:consumeCompleted().sourceWarpId, 0)
end

function T.stair_warps_skip_coordinate_suppression()
  -- The destination stair tile is a standing warp, so pressing the gate
  -- direction on it re-arms the transition immediately -- no suppression.
  local transition, source = transitionFixture({ behavior = BEHAVIOR_STAIRS_WEST, player = stubPlayer() })
  transition:start(source, DOOR_WARP, "west")
  for _ = 1, 4 do
    transition:updateFixed()
  end
  Assert.isNil(transition.suppression, "stair warps re-arm immediately")
end

function T.stair_climb_duration_is_configurable()
  local transition
  local source
  local sounds
  transition, source, _, _, sounds =
    transitionFixture({ behavior = BEHAVIOR_STAIRS_WEST, player = stubPlayer(), stairClimbTicks = 1 })
  transition:start(source, DOOR_WARP, "west")
  Assert.equal(#sounds, 0)
  transition:updateFixed()
  Assert.equal(#sounds, 1, "a one-tick climb fires the sound on its only tick")
end

function T.plain_warps_never_play_the_stair_choreography()
  local player = stubPlayer()
  local transition
  local source
  local sounds
  transition, source, _, _, sounds = transitionFixture({ behavior = 110, player = player })
  transition:start(source, DOOR_WARP, "north")
  for _ = 1, 6 do
    Assert.isFalse(transition:updateFixed(), "a plain fade never reports locomotion")
  end
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.stairActive)
  Assert.deepEqual(sounds, {}, "plain warps play no stair sound")
  Assert.deepEqual(player.steps, {})
end

return { tests = T }
