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

return { tests = T }
