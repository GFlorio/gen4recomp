-- FieldTransition tests freeze the project fade cadence, black-only swap,
-- resource protection, input lock, completion event, and arrival suppression.
-- Failure paths must abort to a coherent idle state: pins released, unlock
-- restored, and the error recorded separately so a later start always works.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.engine.src.FieldTransition")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

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
  local protections, swaps = {}, {}
  local loader = {
    load = function()
      return destination
    end,
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
    swap = function(result, facing)
      swaps[#swaps + 1] = { result = result, facing = facing }
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
  Assert.equal(#swaps, 0)
  transition:updateFixed()
  Assert.equal(transition.phase, "fade_in")
  Assert.equal(transition.fadeAlpha, 1)
  Assert.equal(#swaps, 1)
  Assert.equal(swaps[1].facing, "south")
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
  Assert.deepEqual(protections, {
    { 61, true },
    { 60, true },
    { 61, false },
  })
end

-- The default resolver is WarpSystem.resolveDestination: a transition built
-- without a custom resolver must resolve a scripted direct warp record (the
-- production wiring FieldRuntime relies on) through the moved branch.
function T.default_resolver_handles_direct_warp_records()
  local destination = {
    mapId = 60,
    coordinateOrigin = { x = 672, z = 384 },
    fieldData = { events = { warps = {} } },
    permissions = {
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
    protectMap = function() end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 1,
    fadeInTicks = 1,
    swap = function() end,
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

-- A failed resolution aborts to a coherent idle state: unlocked, pins
-- released, source state cleared, and the error recorded separately. A later
-- start must run a full transition to completion.
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
    swap = function() end,
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
  Assert.deepEqual(loader.protections, {
    { 61, true },
    { 61, false },
    { 61, true },
    { 60, true },
    { 61, false },
  })
end

-- A failing destination pin aborts: the source pin is released and the
-- partially pinned destination is released too.
function T.destination_pin_failure_aborts_with_pins_released()
  local protections = {}
  local loader = {
    protectMap = function(_, mapId, protected)
      protections[#protections + 1] = { mapId, protected }
      if protected and mapId == 60 then
        error("pin failed", 0)
      end
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 1,
    fadeInTicks = 1,
    resolveDestination = destination,
    swap = function() end,
  })
  transition:start({ mapId = 61 }, { index = 0, destinationMapId = 60, destinationWarpId = 0 }, "south")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(tostring(transition.error), "pin failed")
  Assert.isNil(transition.sourceMap)
  Assert.deepEqual(protections, {
    { 61, true },
    { 60, true },
    { 61, false },
    { 60, false },
  })
end

-- A failing source pin at start aborts before the transition begins: idle,
-- unlocked, error recorded, nothing left pinned.
function T.source_pin_failure_at_start_aborts_idle()
  local protections = {}
  local loader = {
    protectMap = function(_, mapId, protected)
      protections[#protections + 1] = { mapId, protected }
      if protected then
        error("pin failed", 0)
      end
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 1,
    fadeInTicks = 1,
    resolveDestination = destination,
    swap = function() end,
  })
  transition:start({ mapId = 61 }, { index = 0, destinationMapId = 60, destinationWarpId = 0 }, "south")
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(tostring(transition.error), "pin failed")
  Assert.isNil(transition.sourceMap)
  Assert.deepEqual(protections, { { 61, true }, { 61, false } })
end

-- A failing swap callback aborts after the destination was pinned: both pins
-- are released and a later start is accepted.
function T.swap_failure_aborts_and_releases_both_pins()
  local loader = recordingLoader()
  local transition = FieldTransition.new({
    loader = loader,
    fadeOutTicks = 1,
    fadeInTicks = 1,
    resolveDestination = destination,
    swap = function()
      error("swap failed", 0)
    end,
  })
  transition:start({ mapId = 61 }, { index = 0, destinationMapId = 60, destinationWarpId = 0 }, "south")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(transition.phase, "swap_map")
  transition:updateFixed()
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(transition.fadeAlpha, 0)
  Assert.equal(tostring(transition.error), "swap failed")
  Assert.isNil(transition.sourceMap)
  Assert.isNil(transition.sourceWarp)
  Assert.isNil(transition.resolution)
  Assert.deepEqual(loader.protections, {
    { 61, true },
    { 60, true },
    { 61, false },
    { 60, false },
  })

  transition:start({ mapId = 61 }, { index = 0, destinationMapId = 60, destinationWarpId = 0 }, "south")
  Assert.equal(transition.phase, "fade_out")
  Assert.isTrue(transition.locked)
  Assert.isNil(transition.error)
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
    swap = function() end,
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

return T
