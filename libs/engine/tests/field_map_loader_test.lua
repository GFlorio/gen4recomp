-- FieldMapLoader tests use injected CPU-only resource loaders to exercise the
-- aggregate and LRU ownership contract without constructing LÖVE GPU objects.

local Assert = require("tests.support.Assert")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")

local T = {}

local function fixture(mapCount)
  local files, world = {}, { maps = {}, byId = {}, bySymbol = {} }
  for mapId = 0, mapCount - 1 do
    local symbol = "MAP_" .. mapId
    local scene = {
      schema = "g4-map-scene-v2", mapId = mapId, mapSymbol = symbol,
      cameraType = mapId, neighbors = {},
      matrix = { width = 1, height = 1, x = 0, z = 0,
        worldOriginX = mapId * 32, worldOriginZ = 0 },
    }
    files[string.format("data/generated/maps/%04d/scene.lua", mapId)] = scene
    files[string.format("data/generated/maps/%04d/terrain.lua", mapId)] = {
      schema = "g4-terrain-surfaces-v1", plates = {},
    }
    files[string.format("data/generated/field/maps/%04d/field.lua", mapId)] = {
      schema = "g4-field-map-v1", mapId = mapId, mapSymbol = symbol,
      cameraType = mapId, events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    }
    world.maps[#world.maps + 1] = { id = mapId, symbol = symbol }
    world.byId[mapId] = #world.maps
    world.bySymbol[symbol] = mapId
  end
  local releases = {}
  local cache = { loadLua = function(_, path) return files[path] end }
  local sceneLoader = { load = function(_, scene)
    return {
      scene = scene, collision = { containsLocal = function() return true end },
      release = function()
        releases[scene.mapId] = (releases[scene.mapId] or 0) + 1
      end,
    }
  end }
  return cache, world, sceneLoader, releases, files
end

function T.loads_visual_field_permission_and_terrain_into_one_aggregate()
  local cache, world, sceneLoader = fixture(1)
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader, capacity = 4 })
  local map = loader:load("MAP_0")
  Assert.equal(map.mapId, 0)
  Assert.equal(map.sceneRuntime.scene.mapSymbol, "MAP_0")
  Assert.equal(map.fieldData.schema, "g4-field-map-v1")
  Assert.equal(map.permissions, map.sceneRuntime.collision)
  Assert.equal(map.terrain.artifact.schema, "g4-terrain-surfaces-v1")
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

function T.missing_prefetch_cells_do_not_reject_loaded_visible_cells()
  local cache, world, sceneLoader, _, files = fixture(1)
  local scene = files["data/generated/maps/0000/scene.lua"]
  scene.matrix = { width = 5, height = 5, x = 2, z = 2,
    worldOriginX = 64, worldOriginZ = 64 }
  scene.neighbors = {}
  for z = -1, 1 do
    for x = -1, 1 do
      if x ~= 0 or z ~= 0 then
        scene.neighbors[#scene.neighbors + 1] = {
          offsetTilesX = x * 32, offsetTilesZ = z * 32,
        }
      end
    end
  end
  local coverageLoader = { load = function()
    return { draws = {}, release = function() end }
  end }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader, coverageLoader = coverageLoader,
  })
  local map = loader:load(0)
  local camera = {
    eye = { x = 16, y = 10, z = 0 },
    target = { x = 16, y = 0, z = 0 },
    up = { x = 0, y = 0, z = -1 },
    projectionAspect = 1,
    profile = {
      projectionType = "orthographic", halfFovRadians = math.atan(0.01),
      distanceTiles = 10, nearTiles = 1, farTiles = 20,
    },
  }
  local plan = loader:updateCoverage(map, camera, { minY = 0, maxY = 0 })
  Assert.equal(#plan.missingPrefetchCells, 3)
  for _, cell in ipairs(plan.cells) do Assert.isTrue(cell.x <= 3) end
  loader:release()
end

return T
