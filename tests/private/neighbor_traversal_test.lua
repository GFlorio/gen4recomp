-- Private connected-cell traversal proves New Bark's compiled west/east
-- neighbors provide permission and BDHC data for real cross-boundary steps.

local Assert = require("tests.support.Assert")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local CacheFs = require("libs.rom.src.CacheFs")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldRegion = require("libs.engine.src.FieldRegion")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local PermissionGrid = require("libs.assets.src.PermissionGrid")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function collision(bytes, context)
  return CollisionGrid.new(assert(PermissionGrid.decode(bytes, context)))
end

local function runtimeMap(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local neighbors = {}
  for _, descriptor in ipairs(bundle.scene.neighbors) do
    local chunk = assert(bundle.neighborChunks[descriptor.landDataMemberId])
    neighbors[#neighbors + 1] = {
      offsetTilesX = descriptor.offsetTilesX,
      offsetTilesZ = descriptor.offsetTilesZ,
      collision = collision(chunk.permissions, descriptor.landDataMemberId),
      terrain = TerrainSurface.new(chunk.terrain),
    }
  end
  local region =
    FieldRegion.new(collision(bundle.permissions, bundle.mapId), TerrainSurface.new(bundle.terrain), neighbors)
  return {
    mapId = bundle.mapId,
    coordinateOrigin = {
      x = bundle.scene.matrix.worldOriginX,
      z = bundle.scene.matrix.worldOriginZ,
    },
    permissions = region.permissions,
    terrain = region.terrain,
  },
    bundle.scene.neighbors
end

local function crossesBoundary(map, sourceX, destinationX, direction)
  for z = 0, 31 do
    if not map.permissions:isBlockedLocal(sourceX, z) and not map.permissions:isBlockedLocal(destinationX, z) then
      for _, plate in ipairs(map.terrain:candidatesAt(sourceX + 0.5, z + 0.5)) do
        local player = FieldPlayer.new({
          currentMap = map,
          fieldX = map.coordinateOrigin.x + sourceX,
          fieldZ = map.coordinateOrigin.z + z,
          surfaceId = plate.id,
          facing = direction,
        })
        if player:tryStep(direction) then
          for _ = 1, FieldPlayer.WALK_STEP_TICKS do
            player:updateFixed({})
          end
          Assert.equal(player.fieldX, map.coordinateOrigin.x + destinationX)
          return z
        end
      end
    end
  end
  return nil
end

function T.new_bark_crosses_into_route_29_and_route_27_cells(romFs)
  local map, descriptors = runtimeMap(romFs)
  local westHeader, eastHeader
  for _, descriptor in ipairs(descriptors) do
    if descriptor.offsetTilesX == -32 and descriptor.offsetTilesZ == 0 then
      westHeader = descriptor.mapHeaderId
    elseif descriptor.offsetTilesX == 32 and descriptor.offsetTilesZ == 0 then
      eastHeader = descriptor.mapHeaderId
    end
  end
  Assert.equal(westHeader, 33)
  Assert.equal(eastHeader, 31)
  Assert.notNil(crossesBoundary(map, 0, -1, "west"), "no Route 29 boundary crossing")
  Assert.notNil(crossesBoundary(map, 31, 32, "east"), "no Route 27 boundary crossing")
end

function T.generated_cache_loads_as_traversable_region(_, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()))
  local sceneLoader = {
    load = function(cache, scene)
      local grid = assert(PermissionGrid.decode(assert(cache:read(scene.collision.file)), scene.mapId))
      return { collision = CollisionGrid.new(grid), release = function() end }
    end,
  }
  local coverageLoader = {
    load = function()
      return { draws = {}, release = function() end }
    end,
  }
  local loader = FieldMapLoader.new(cacheFs, world, {
    sceneLoader = sceneLoader,
    coverageLoader = coverageLoader,
  })
  local map = loader:load(60)
  Assert.notNil(crossesBoundary(map, 0, -1, "west"))
  Assert.notNil(crossesBoundary(map, 31, 32, "east"))
  loader:release()
end

return T
