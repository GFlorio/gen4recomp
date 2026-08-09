-- FieldRegion tests cover permission routing and translated BDHC surfaces over
-- the central cell plus cached neighbors, including a connected edge crossing.

local Assert = require("tests.support.Assert")
local FieldRegion = require("libs.engine.src.FieldRegion")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function collision(blocked)
  return {
    containsLocal = function(_, x, z)
      return x >= 0 and x < 32 and z >= 0 and z < 32
    end,
    isBlockedLocal = function(_, x, z)
      return blocked and blocked[x .. ":" .. z] or false
    end,
    getLocal = function(_, x, z)
      return { x = x, z = z, hardBlocked = false }
    end,
  }
end

local function flatTerrain(height)
  return TerrainSurface.new({
    schema = "g4-terrain-surfaces-v1",
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = height,
        slopeClass = "flat",
        walkable = true,
      },
    },
  })
end

function T.routes_collision_to_neighbor_cell_coordinates()
  local region = FieldRegion.new(collision(), flatTerrain(0), {
    { offsetTilesX = 32, offsetTilesZ = 0, collision = collision({ ["0:4"] = true }), terrain = flatTerrain(0) },
  })
  Assert.isTrue(region.permissions:containsLocal(63, 4))
  Assert.isFalse(region.permissions:containsLocal(64, 4))
  Assert.isTrue(region.permissions:isBlockedLocal(32, 4))
  Assert.isFalse(region.permissions:isBlockedLocal(31, 4))
  Assert.equal(region.permissions:getLocal(33, 5).x, 1)
end

function T.translates_neighbor_surfaces_and_connects_shared_edge()
  local region = FieldRegion.new(collision(), flatTerrain(2), {
    { offsetTilesX = 32, offsetTilesZ = 0, collision = collision(), terrain = flatTerrain(2) },
  })
  local candidates = region.terrain:candidatesAt(32.5, 4.5)
  Assert.equal(#candidates, 1)
  Assert.equal(candidates[1].sourceSurfaceId, 0)
  Assert.equal(candidates[1].cellOffsetX, 32)
  Assert.equal(region.terrain:sampleHeight(candidates[1].id, 32.5, 4.5), 2)

  local resolved = SurfaceResolver.new(region.terrain):resolve({
    localX = 32.5,
    localZ = 4.5,
    currentSurfaceId = 0,
    currentY = 2,
    crossing = { fromX = 31.5, fromZ = 4.5, toX = 32.5, toZ = 4.5 },
  })
  Assert.equal(resolved.surfaceId, candidates[1].id)
end

function T.translates_sloped_plane_distance_without_changing_height()
  local slope = TerrainSurface.new({
    plates = {
      {
        id = 4,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = -1, y = 1, z = 0 },
        distance = 0,
        slopeClass = "ramp-east",
        walkable = true,
      },
    },
  })
  local region = FieldRegion.new(collision(), flatTerrain(0), {
    { offsetTilesX = -32, offsetTilesZ = 32, collision = collision(), terrain = slope },
  })
  local plate = region.terrain:candidatesAt(-31.5, 32.5)[1]
  Assert.equal(region.terrain:sampleHeight(plate.id, -31.5, 32.5), 0.5)
end

return T
