-- FieldTransition tests freeze the project fade cadence, black-only swap,
-- resource protection, input lock, completion event, and arrival suppression.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.engine.src.FieldTransition")

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

return T
