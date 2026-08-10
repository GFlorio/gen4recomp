-- FieldMapLoader tests use injected CPU-only resource loaders to exercise the
-- aggregate and LRU ownership contract without constructing LÖVE GPU objects.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")

local T = {}

local function fixture(mapCount)
  local files, world = {}, { maps = {}, byId = {}, bySymbol = {} }
  for mapId = 0, mapCount - 1 do
    local symbol = "MAP_" .. mapId
    local scene = {
      schema = "g4-map-scene-v3",
      mapId = mapId,
      mapSymbol = symbol,
      cameraType = mapId,
      neighbors = {},
      matrix = { width = 1, height = 1, x = 0, z = 0, worldOriginX = mapId * 32, worldOriginZ = 0 },
    }
    files[string.format("data/generated/maps/%04d/scene.lua", mapId)] = scene
    files[string.format("data/generated/maps/%04d/terrain.lua", mapId)] = {
      schema = "g4-terrain-surfaces-v1",
      source = { bdhcSha1 = "central-" .. mapId },
      plates = {},
    }
    files[string.format("data/generated/field/maps/%04d/field.lua", mapId)] = {
      schema = "g4-field-map-v1",
      mapId = mapId,
      mapSymbol = symbol,
      cameraType = mapId,
      events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    }
    world.maps[#world.maps + 1] = { id = mapId, symbol = symbol }
    world.byId[mapId] = #world.maps
    world.bySymbol[symbol] = mapId
  end
  local releases = {}
  local cache = {
    loadLua = function(_, path)
      return files[path]
    end,
    read = function(_, path)
      return files[path]
    end,
  }
  local sceneLoader = {
    load = function(_, scene)
      return {
        scene = scene,
        collision = {
          containsLocal = function()
            return true
          end,
        },
        release = function()
          releases[scene.mapId] = (releases[scene.mapId] or 0) + 1
        end,
      }
    end,
  }
  return cache, world, sceneLoader, releases, files
end

function T.loads_visual_field_permission_and_terrain_into_one_aggregate()
  local cache, world, sceneLoader = fixture(1)
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader, capacity = 4 })
  local map = loader:load("MAP_0")
  Assert.equal(map.mapId, 0)
  Assert.equal(map.sceneRuntime.scene.mapSymbol, "MAP_0")
  Assert.equal(map.fieldData.schema, "g4-field-map-v1")
  Assert.equal(map.fieldRegion.cells[1].collision, map.sceneRuntime.collision)
  Assert.equal(map.terrain.artifact.schema, "g4-composite-terrain-v1")
  Assert.deepEqual(map.coordinateOrigin, { x = 0, z = 0 })
  loader:release()
end

function T.evicts_the_least_recently_used_unprotected_map()
  local cache, world, sceneLoader, releases = fixture(3)
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader, capacity = 2 })
  loader:load(0)
  loader:load(1)
  loader:load(0)
  loader:load(2)
  Assert.notNil(loader:get(0))
  Assert.isNil(loader:get(1))
  Assert.notNil(loader:get(2))
  Assert.equal(releases[1], 1)
  loader:release()
end

function T.protection_defers_eviction_and_release_is_exactly_once()
  local cache, world, sceneLoader, releases = fixture(2)
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader, capacity = 1 })
  local first = loader:load(0)
  loader:protectMap(0, true)
  loader:load(1)
  Assert.equal(loader:residentCount(), 2)
  loader:protectMap(0, false)
  Assert.isNil(loader:get(0))
  Assert.equal(releases[0], 1)
  first:release()
  Assert.equal(releases[0], 1)
  loader:release()
  loader:release()
  Assert.equal(releases[1], 1)
end

function T.visible_cell_protection_keeps_its_aggregate_resident()
  local cache, world, sceneLoader, releases = fixture(2)
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader, capacity = 1 })
  loader:load(0)
  loader:protectCells(0, { { x = 0, z = 0 } })
  loader:load(1)
  Assert.notNil(loader:get(0))
  Assert.equal(loader:residentCount(), 2)
  loader:protectCells(0, {})
  Assert.isNil(loader:get(0))
  Assert.equal(releases[0], 1)
  loader:release()
end

function T.round_trip_reuses_both_resident_map_aggregates()
  local cache, world, sceneLoader, releases = fixture(2)
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader, capacity = 4 })
  local first = loader:load(0)
  local second = loader:load(1)
  for _ = 1, 10 do
    Assert.equal(loader:load(0), first)
    Assert.equal(loader:load(1), second)
  end
  Assert.equal(loader:residentCount(), 2)
  Assert.isNil(releases[0])
  Assert.isNil(releases[1])
  loader:release()
end

function T.composes_neighbor_permissions_and_terrain_into_runtime_map()
  local cache, world, _, _, files = fixture(1)
  local permissionPath = "data/generated/maps/0000/neighbors/3/permissions.bin"
  local terrainPath = "data/generated/maps/0000/neighbors/3/terrain.lua"
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    {
      offsetTilesX = 32,
      offsetTilesZ = 0,
      collision = { file = permissionPath },
      terrain = { file = terrainPath },
      batches = {},
      materials = {},
    },
  }
  files[terrainPath] = {
    schema = "g4-terrain-surfaces-v1",
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
        walkable = true,
      },
    },
    source = { bdhcSha1 = "east" },
  }
  local bytes = {}
  for index = 0, 1023 do
    bytes[#bytes + 1] = string.char(0, index == 4 * 32 and 128 or 0)
  end
  local blobs = { [permissionPath] = table.concat(bytes) }
  cache.read = function(_, path)
    return blobs[path]
  end
  local centralCollision = {
    containsLocal = function(_, x, z)
      return x >= 0 and x < 32 and z >= 0 and z < 32
    end,
    isBlockedLocal = function()
      return false
    end,
    getLocal = function()
      return { hardBlocked = false }
    end,
  }
  local sceneLoader = {
    load = function()
      return { collision = centralCollision, release = function() end }
    end,
  }
  local coverageLoader = {
    load = function()
      return { draws = {}, release = function() end }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    coverageLoader = coverageLoader,
  })
  local map = loader:load(0)
  Assert.equal(map.terrainDependencyHash, "g4-composite-terrain-v1|0:0:central-0|32:0:east")
  Assert.isTrue(map.permissions:containsLocal(32, 4))
  Assert.isTrue(map.permissions:isBlockedLocal(32, 4))
  local candidates = map.terrain:candidatesAt(32.5, 4.5)
  Assert.equal(#candidates, 1)
  Assert.equal(candidates[1].cellOffsetX, 32)
  loader:release()
end

function T.missing_prefetch_cells_do_not_reject_loaded_visible_cells()
  local cache, world, sceneLoader, _, files = fixture(1)
  local scene = files["data/generated/maps/0000/scene.lua"]
  scene.matrix = { width = 5, height = 5, x = 2, z = 2, worldOriginX = 64, worldOriginZ = 64 }
  scene.neighbors = {}
  for z = -1, 1 do
    for x = -1, 1 do
      if x ~= 0 or z ~= 0 then
        local key = x .. "_" .. z
        local permissionPath = "neighbor_" .. key .. ".bin"
        local terrainPath = "neighbor_" .. key .. ".lua"
        files[permissionPath] = string.rep("\0", 2048)
        files[terrainPath] = { schema = "g4-terrain-surfaces-v1", plates = {} }
        scene.neighbors[#scene.neighbors + 1] = {
          offsetTilesX = x * 32,
          offsetTilesZ = z * 32,
          collision = { file = permissionPath },
          terrain = { file = terrainPath },
        }
      end
    end
  end
  local coverageLoader = {
    load = function()
      return { draws = {}, release = function() end }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    coverageLoader = coverageLoader,
  })
  local map = loader:load(0)
  local camera = {
    eye = { x = 16, y = 10, z = 0 },
    target = { x = 16, y = 0, z = 0 },
    up = { x = 0, y = 0, z = -1 },
    projectionAspect = 1,
    profile = {
      projectionType = "orthographic",
      halfFovRadians = math.atan(0.01),
      distanceTiles = 10,
      nearTiles = 1,
      farTiles = 20,
    },
  }
  local plan = loader:updateCoverage(map, camera, { minY = 0, maxY = 0 })
  Assert.equal(#plan.missingPrefetchCells, 3)
  for _, cell in ipairs(plan.cells) do
    Assert.isTrue(cell.x <= 3)
  end
  loader:release()
end

function T.finite_neighbor_region_reports_missing_visible_cells_without_crashing()
  local cache, world, sceneLoader, _, files = fixture(1)
  local scene = files["data/generated/maps/0000/scene.lua"]
  scene.matrix = { width = 5, height = 5, x = 2, z = 2, worldOriginX = 64, worldOriginZ = 64 }
  scene.neighbors = {}
  for z = -1, 1 do
    for x = -1, 1 do
      if x ~= 0 or z ~= 0 then
        local key = x .. "_" .. z
        local permissionPath = "finite_" .. key .. ".bin"
        local terrainPath = "finite_" .. key .. ".lua"
        files[permissionPath] = string.rep("\0", 2048)
        files[terrainPath] = { schema = "g4-terrain-surfaces-v1", plates = {} }
        scene.neighbors[#scene.neighbors + 1] = {
          offsetTilesX = x * 32,
          offsetTilesZ = z * 32,
          collision = { file = permissionPath },
          terrain = { file = terrainPath },
        }
      end
    end
  end
  local coverageLoader = {
    load = function()
      return { draws = {}, release = function() end }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    coverageLoader = coverageLoader,
  })
  local map = loader:load(0)
  local camera = {
    eye = { x = 55, y = 10, z = 0 },
    target = { x = 55, y = 0, z = 0 },
    up = { x = 0, y = 0, z = -1 },
    projectionAspect = 1,
    profile = {
      projectionType = "orthographic",
      halfFovRadians = math.atan(1),
      distanceTiles = 10,
      nearTiles = 1,
      farTiles = 20,
    },
  }
  local plan = loader:updateCoverage(map, camera, { minY = 0, maxY = 0 })
  Assert.isTrue(#plan.missingVisibleCells > 0)
  loader:release()
end

-- A failed coverage load releases the acquired scene runtime exactly once
-- (locks in the existing behavior before the post-scene transaction extends
-- the same cleanup to later failures).
function T.failed_coverage_load_releases_the_scene_runtime()
  local cache, world, sceneLoader, releases, files = fixture(1)
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    { offsetTilesX = 32, offsetTilesZ = 0, batches = {}, materials = {} },
  }
  local coverageLoader = {
    load = function()
      error("injected coverage failure")
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    coverageLoader = coverageLoader,
  })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(tostring(err):find("injected coverage failure", 1, true) ~= nil, "the coverage failure propagates")
  Assert.equal(releases[0], 1, "the scene runtime is released exactly once")
  loader:release()
  Assert.equal(releases[0], 1, "release stays exactly once")
end

-- A malformed terrain artifact fails construction after both the scene runtime
-- and the coverage runtime were acquired; both must be released.
function T.failed_terrain_construction_releases_scene_and_coverage()
  local cache, world, sceneLoader, releases, files = fixture(1)
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    { offsetTilesX = 32, offsetTilesZ = 0, batches = {}, materials = {} },
  }
  files["data/generated/maps/0000/terrain.lua"] = { schema = "g4-terrain-surfaces-v1" }
  local coverageReleases = 0
  local coverageLoader = {
    load = function()
      return {
        draws = {},
        release = function()
          coverageReleases = coverageReleases + 1
        end,
      }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    coverageLoader = coverageLoader,
  })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(tostring(err):find("TerrainSurface.new requires a terrain artifact", 1, true) ~= nil)
  Assert.equal(releases[0], 1, "the scene runtime is released")
  Assert.equal(coverageReleases, 1, "the coverage runtime is released")
  loader:release()
  Assert.equal(releases[0], 1, "scene release stays exactly once")
  Assert.equal(coverageReleases, 1, "coverage release stays exactly once")
end

-- Malformed neighbor permissions fail neighbor decoding after both runtimes
-- were acquired; both must be released.
function T.failed_neighbor_permission_decode_releases_scene_and_coverage()
  local cache, world, sceneLoader, releases, files = fixture(1)
  local permissionPath = "data/generated/maps/0000/neighbors/3/permissions.bin"
  local terrainPath = "data/generated/maps/0000/neighbors/3/terrain.lua"
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    {
      offsetTilesX = 32,
      offsetTilesZ = 0,
      collision = { file = permissionPath },
      terrain = { file = terrainPath },
    },
  }
  files[permissionPath] = string.rep("\0", 10)
  files[terrainPath] = { schema = "g4-terrain-surfaces-v1", plates = {} }
  local coverageReleases = 0
  local coverageLoader = {
    load = function()
      return {
        draws = {},
        release = function()
          coverageReleases = coverageReleases + 1
        end,
      }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    coverageLoader = coverageLoader,
  })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(Errors.is(err) and err.code == "PERMISSION_BAD_SIZE", "the permission failure propagates")
  Assert.equal(releases[0], 1, "the scene runtime is released")
  Assert.equal(coverageReleases, 1, "the coverage runtime is released")
  loader:release()
  Assert.equal(releases[0], 1, "scene release stays exactly once")
  Assert.equal(coverageReleases, 1, "coverage release stays exactly once")
end

return T
