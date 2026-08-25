-- ROM-conformance connected-cell traversal proves New Bark's compiled west/east
-- neighbors provide collision and BDHC data for real cross-boundary steps.

local Assert = require("tests.support.Assert")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldRegion = require("libs.engine.src.FieldRegion")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function collision(grid)
  return CollisionGrid.new(grid)
end

local function runtimeMap(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local neighbors = {}
  for _, descriptor in ipairs(bundle.scene.neighbors) do
    local chunk = assert(bundle.neighborChunks[descriptor.landDataMemberId])
    neighbors[#neighbors + 1] = {
      offsetTilesX = descriptor.offsetTilesX,
      offsetTilesY = descriptor.offsetTilesY,
      offsetTilesZ = descriptor.offsetTilesZ,
      collision = collision(chunk.collision),
      terrain = TerrainSurface.new(chunk.terrain),
    }
  end
  local region = FieldRegion.new(collision(bundle.collision), TerrainSurface.new(bundle.terrain), neighbors)
  return {
    mapId = bundle.mapId,
    coordinateOrigin = {
      x = bundle.scene.matrix.worldOriginX,
      z = bundle.scene.matrix.worldOriginZ,
    },
    collision = region.collision,
    terrain = region.terrain,
  },
    bundle.scene.neighbors
end

local function crossesBoundary(map, sourceX, destinationX, direction)
  for z = 0, 31 do
    if not map.collision:isBlockedLocal(sourceX, z) and not map.collision:isBlockedLocal(destinationX, z) then
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

function T.new_bark_crosses_into_route_29_and_route_27_cells(romFs, versionId)
  -- Compiled-bundle region: the same crossings must hold from fresh ROM
  -- compilation, which also pins the neighbor header mapping.
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

  -- Generated-cache region: the production loader path must yield the same
  -- traversable neighbor ring for the same boundary steps. No scene loader is
  -- needed: collision and terrain load through the pure asset paths.
  local cacheFs = CacheFs.forVersion(versionId)
  local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()))
  local loader = FieldMapLoader.new(cacheFs, world)
  local cached = loader:load(60)
  Assert.notNil(crossesBoundary(cached, 0, -1, "west"))
  Assert.notNil(crossesBoundary(cached, 31, 32, "east"))
  loader:release()
end

return require("tests.rom.support.RomSuite").fromFacts(T)
