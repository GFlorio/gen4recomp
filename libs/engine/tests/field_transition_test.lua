-- FieldTransition tests freeze the project fade cadence, black-only swap,
-- resource protection, input lock, completion event, and arrival suppression.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.engine.src.FieldTransition")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

function T.fades_loads_swaps_while_black_and_completes()
  local source = { mapId = 61 }
  local destination = { mapId = 60 }
  local warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 }
  local protections, cellProtections, swaps = {}, {}, {}
  local loader = {
    load = function()
      return destination
    end,
    protectMap = function(_, mapId, protected)
      protections[#protections + 1] = { mapId, protected }
    end,
    protectCells = function(_, mapId, cells)
      cellProtections[#cellProtections + 1] = { mapId, #cells }
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
  Assert.deepEqual(cellProtections, { { 61, 0 } })
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
    protectCells = function() end,
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

return T
