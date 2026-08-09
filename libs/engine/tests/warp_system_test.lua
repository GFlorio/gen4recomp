-- WarpSystem tests cover coordinate lookup, indexed destination resolution,
-- terrain-height selection, typed failures, and one-coordinate suppression.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local TerrainSurface = require("libs.engine.src.TerrainSurface")
local WarpSystem = require("libs.engine.src.WarpSystem")

local T = {}

local function runtimeMap(mapId, originX, originZ, warps, plates)
  return {
    mapId = mapId,
    coordinateOrigin = { x = originX, z = originZ },
    fieldData = { events = { warps = warps } },
    permissions = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({
      plates = plates or {
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
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected structured error")
  Assert.equal(err.code, code)
end

function T.finds_warp_by_authoritative_field_coordinate()
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = runtimeMap(61, 0, 0, { warp })
  Assert.equal(WarpSystem.findAt(map, 4, 14), warp)
  Assert.isNil(WarpSystem.findAt(map, 4, 13))
end

function T.resolves_destination_warp_and_nearest_height_surface()
  local sourceWarp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local destinationWarp = { index = 0, x = 684, z = 393, destinationMapId = 61, destinationWarpId = 0, y = 32 }
  local destination = runtimeMap(60, 672, 384, { destinationWarp }, {
    {
      id = 3,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
      slopeClass = "flat",
    },
    {
      id = 7,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 2,
      slopeClass = "flat",
    },
  })
  local loader = {
    load = function(_, mapId)
      Assert.equal(mapId, 60)
      return destination
    end,
  }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(61, 0, 0, { sourceWarp }), sourceWarp)
  Assert.equal(result.destinationMap, destination)
  Assert.equal(result.destinationWarp, destinationWarp)
  Assert.equal(result.fieldX, 684)
  Assert.equal(result.fieldZ, 393)
  Assert.equal(result.surfaceId, 7)
  Assert.equal(result.worldY, 2)
  Assert.deepEqual(result.suppression, { mapId = 60, fieldX = 684, fieldZ = 393 })
end

function T.rejects_dynamic_and_missing_destination_warps()
  local destination = runtimeMap(60, 0, 0, {})
  local loader = {
    load = function()
      return destination
    end,
  }
  local source = runtimeMap(61, 0, 0, {})
  throwsCode("FIELD_DYNAMIC_WARP_UNSUPPORTED", function()
    WarpSystem.resolveDestination(loader, source, { index = 0, destinationMapId = 60, destinationWarpId = 0x100 })
  end)
  throwsCode("FIELD_DESTINATION_WARP_UNKNOWN", function()
    WarpSystem.resolveDestination(loader, source, { index = 0, destinationMapId = 60, destinationWarpId = 4 })
  end)
end

function T.suppression_lasts_until_the_player_leaves_its_coordinate()
  local token = { mapId = 60, fieldX = 684, fieldZ = 393 }
  Assert.isTrue(WarpSystem.isSuppressed(token, 60, 684, 393))
  Assert.equal(WarpSystem.updateSuppression(token, 60, 684, 393), token)
  Assert.isNil(WarpSystem.updateSuppression(token, 60, 684, 394))
end

return T
