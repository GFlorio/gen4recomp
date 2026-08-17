-- FieldMapLoader tests use injected CPU-only resource loaders to exercise the
-- aggregate and LRU ownership contract without constructing LÖVE GPU objects.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CollisionFixture = require("tests.support.CollisionFixture")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")

local T = {}

-- A structurally valid G4CL header for a 32x32 grid with a truncated cell
-- payload: decodes as COLLISION_BAD_SIZE, proving the artifact class parses
-- before the failure.
local function truncatedCollision()
  return "G4CL" .. string.char(1, 0, 32, 0, 32, 0) .. string.char(0, 0, 0)
end

local function fixture(mapCount)
  local files, world = {}, { maps = {}, byId = {}, bySymbol = {} }
  for mapId = 0, mapCount - 1 do
    local symbol = "MAP_" .. mapId
    local scene = {
      schema = "g4-map-scene-v6",
      mapId = mapId,
      mapSymbol = symbol,
      cameraType = mapId,
      neighbors = {},
      terrainAnimations = { textureSrt = false },
      collision = { file = string.format("data/generated/maps/%04d/collision.g4collision", mapId) },
      matrix = { width = 1, height = 1, x = 0, z = 0, worldOriginX = mapId * 32, worldOriginZ = 0 },
    }
    files[string.format("data/generated/maps/%04d/scene.lua", mapId)] = scene
    files[string.format("data/generated/maps/%04d/terrain.lua", mapId)] = {
      schema = "g4-terrain-surfaces-v1",
      source = { bdhcSha1 = "central-" .. mapId },
      plates = {},
    }
    files[scene.collision.file] = CollisionFixture.asset(32, 32)
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
        release = function()
          releases[scene.mapId] = (releases[scene.mapId] or 0) + 1
        end,
      }
    end,
  }
  return cache, world, sceneLoader, releases, files
end

function T.loads_visual_field_collision_and_terrain_into_one_aggregate()
  local cache, world, sceneLoader = fixture(1)
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader, capacity = 4 })
  local map = loader:load("MAP_0")
  Assert.equal(map.mapId, 0)
  Assert.equal(map.sceneRuntime.scene.mapSymbol, "MAP_0")
  Assert.equal(map.fieldData.schema, "g4-field-map-v1")
  Assert.equal(map.fieldRegion.collision, map.collision)
  Assert.isTrue(map.fieldRegion.cells[1].collision:containsLocal(4, 4))
  Assert.isTrue(map.collision:containsLocal(4, 4))
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

-- A required-cache-file read failure must keep the underlying cause's own
-- message visible in the raised error's formatted text, not merely its bare
-- error code, since presentation surfaces this text directly to the player.
function T.required_cache_file_failure_preserves_the_underlying_cause_message()
  local cache, world, sceneLoader = fixture(1)
  local scenePath = "data/generated/maps/0000/scene.lua"
  local underlying = Errors.new("READ_FAILED", "distinctive injected read failure", { path = scenePath })
  local realLoadLua = cache.loadLua
  cache.loadLua = function(_, path)
    if path == scenePath then
      return nil, underlying
    end
    return realLoadLua(cache, path)
  end
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(
    tostring(err):find("distinctive injected read failure", 1, true) ~= nil,
    "the formatted error keeps the underlying cause message"
  )
end

function T.composes_neighbor_collision_and_terrain_into_runtime_map()
  local cache, world, _, _, files = fixture(1)
  local collisionPath = "data/generated/maps/0000/neighbors/3/collision.g4collision"
  local terrainPath = "data/generated/maps/0000/neighbors/3/terrain.lua"
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    {
      offsetTilesX = 32,
      offsetTilesZ = 0,
      collision = { file = collisionPath },
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
  files[collisionPath] = CollisionFixture.asset(32, 32, { { x = 0, z = 4 } })
  local neighborLoader = {
    load = function()
      return { draws = {}, release = function() end }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, { neighborLoader = neighborLoader })
  local map = loader:load(0)
  Assert.equal(map.terrainDependencyHash, "g4-composite-terrain-v1|0:0:central-0|32:0:east")
  Assert.isTrue(map.collision:containsLocal(32, 4))
  Assert.isTrue(map.collision:isBlockedLocal(32, 4))
  Assert.isFalse(map.collision:isBlockedLocal(33, 4))
  local candidates = map.terrain:candidatesAt(32.5, 4.5)
  Assert.equal(#candidates, 1)
  Assert.equal(candidates[1].cellOffsetX, 32)
  loader:release()
end

-- A failed neighbor-ring load releases the acquired scene runtime exactly once
-- (locks in the existing behavior before the post-scene transaction extends
-- the same cleanup to later failures).
function T.failed_neighbor_load_releases_the_scene_runtime()
  local cache, world, sceneLoader, releases, files = fixture(1)
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    { offsetTilesX = 32, offsetTilesZ = 0, batches = {}, materials = {} },
  }
  local neighborLoader = {
    load = function()
      error("injected neighbor failure")
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    neighborLoader = neighborLoader,
  })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(tostring(err):find("injected neighbor failure", 1, true) ~= nil, "the neighbor failure propagates")
  Assert.equal(releases[0], 1, "the scene runtime is released exactly once")
  loader:release()
  Assert.equal(releases[0], 1, "release stays exactly once")
end

-- The central collision decodes inside the load transaction; malformed
-- generated data must fail the load after the acquired scene and neighbor
-- runtimes, and both must be released exactly once.
function T.failed_central_collision_decode_releases_scene_and_neighbor()
  local cache, world, sceneLoader, releases, files = fixture(1)
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    { offsetTilesX = 32, offsetTilesZ = 0, batches = {}, materials = {} },
  }
  files["data/generated/maps/0000/collision.g4collision"] = truncatedCollision()
  local neighborReleases = 0
  local neighborLoader = {
    load = function()
      return {
        draws = {},
        release = function()
          neighborReleases = neighborReleases + 1
        end,
      }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    neighborLoader = neighborLoader,
  })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(Errors.is(err) and err.code == "COLLISION_BAD_SIZE", "the collision failure propagates")
  Assert.equal(releases[0], 1, "the scene runtime is released")
  Assert.equal(neighborReleases, 1, "the neighbor runtime is released")
  loader:release()
  Assert.equal(releases[0], 1, "scene release stays exactly once")
  Assert.equal(neighborReleases, 1, "neighbor release stays exactly once")
end

-- A malformed terrain artifact fails construction after both the scene runtime
-- and the neighbor runtime were acquired; both must be released. The source
-- record is present (the strict identity fields), so the failure is the
-- missing plates inside the terrain construction transaction.
function T.failed_terrain_construction_releases_scene_and_neighbor()
  local cache, world, sceneLoader, releases, files = fixture(1)
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    { offsetTilesX = 32, offsetTilesZ = 0, batches = {}, materials = {} },
  }
  files["data/generated/maps/0000/terrain.lua"] = {
    schema = "g4-terrain-surfaces-v1",
    source = { bdhcSha1 = "central-0" },
  }
  local neighborReleases = 0
  local neighborLoader = {
    load = function()
      return {
        draws = {},
        release = function()
          neighborReleases = neighborReleases + 1
        end,
      }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    neighborLoader = neighborLoader,
  })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(tostring(err):find("TerrainSurface.new requires a terrain artifact", 1, true) ~= nil)
  Assert.equal(releases[0], 1, "the scene runtime is released")
  Assert.equal(neighborReleases, 1, "the neighbor runtime is released")
  loader:release()
  Assert.equal(releases[0], 1, "scene release stays exactly once")
  Assert.equal(neighborReleases, 1, "neighbor release stays exactly once")
end

-- The generated scene contract is strict: a scene without a neighbors record
-- is malformed generated data and must fail the load, never load with an
-- empty neighbor set (a partly working map).
function T.map_without_a_neighbors_record_fails_to_load()
  local cache, world, sceneLoader, _, files = fixture(1)
  files["data/generated/maps/0000/scene.lua"].neighbors = nil
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader })
  Assert.throws(function()
    loader:load(0)
  end)
  Assert.isNil(loader:get(0), "no partly loaded aggregate is resident")
  loader:release()
end

-- A scene without a collision descriptor is equally malformed: the central
-- grid is mandatory for every composition, presentation or not.
function T.map_without_a_collision_descriptor_fails_to_load()
  local cache, world, sceneLoader, _, files = fixture(1)
  files["data/generated/maps/0000/scene.lua"].collision = nil
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_MAP_VISUAL_CACHE_INVALID", "the missing descriptor propagates")
  Assert.isNil(loader:get(0), "no partly loaded aggregate is resident")
  loader:release()
end

-- The field record's event collections are part of the authoritative
-- four-array contract: a record missing one collection (here `objects`) is
-- malformed generated data and must fail the load, never enter the game as
-- an empty object set.
function T.map_without_object_events_fails_to_load()
  local cache, world, sceneLoader, _, files = fixture(1)
  files["data/generated/field/maps/0000/field.lua"].events = {
    background = {},
    warps = {},
    coordinates = {},
  }
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_MAP_DATA_CACHE_INVALID", "the malformed record propagates")
  Assert.isNil(loader:get(0), "no partly loaded aggregate is resident")
  loader:release()
end

-- The terrain artifact source record is part of the terrain dependency
-- identity; its absence must fail the load instead of degrading the hash.
function T.map_without_a_terrain_artifact_source_fails_to_load()
  local cache, world, sceneLoader, _, files = fixture(1)
  files["data/generated/maps/0000/terrain.lua"] = { schema = "g4-terrain-surfaces-v1", plates = {} }
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader })
  Assert.throws(function()
    loader:load(0)
  end)
  Assert.isNil(loader:get(0), "no partly loaded aggregate is resident")
  loader:release()
end

-- A source record without its bdhcSha1 is equally malformed: the hash must
-- not silently degrade to "unknown".
function T.map_without_a_terrain_source_sha1_fails_to_load()
  local cache, world, sceneLoader, _, files = fixture(1)
  files["data/generated/maps/0000/terrain.lua"] = {
    schema = "g4-terrain-surfaces-v1",
    plates = {},
    source = {},
  }
  local loader = FieldMapLoader.new(cache, world, { sceneLoader = sceneLoader })
  Assert.throws(function()
    loader:load(0)
  end)
  Assert.isNil(loader:get(0), "no partly loaded aggregate is resident")
  loader:release()
end

-- A neighbor terrain artifact without its source record is equally malformed:
-- the dependency identity covers every region cell, so neighbor cells must not
-- degrade to "unknown". The failure lands inside the load transaction, so the
-- acquired scene and neighbor runtimes are released.
function T.map_without_a_neighbor_terrain_source_fails_to_load()
  local cache, world, sceneLoader, releases, files = fixture(1)
  local collisionPath = "data/generated/maps/0000/neighbors/3/collision.g4collision"
  local terrainPath = "data/generated/maps/0000/neighbors/3/terrain.lua"
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    {
      offsetTilesX = 32,
      offsetTilesZ = 0,
      collision = { file = collisionPath },
      terrain = { file = terrainPath },
    },
  }
  files[collisionPath] = CollisionFixture.asset(32, 32)
  files[terrainPath] = { schema = "g4-terrain-surfaces-v1", plates = {} }
  local neighborReleases = 0
  local neighborLoader = {
    load = function()
      return {
        draws = {},
        release = function()
          neighborReleases = neighborReleases + 1
        end,
      }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    neighborLoader = neighborLoader,
  })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_MAP_TERRAIN_CACHE_INVALID",
    "the terrain identity failure propagates"
  )
  Assert.equal(releases[0], 1, "the scene runtime is released")
  Assert.equal(neighborReleases, 1, "the neighbor runtime is released")
  loader:release()
end

-- Malformed neighbor collision fails neighbor decoding after both runtimes
-- were acquired; both must be released.
function T.failed_neighbor_collision_decode_releases_scene_and_neighbor()
  local cache, world, sceneLoader, releases, files = fixture(1)
  local collisionPath = "data/generated/maps/0000/neighbors/3/collision.g4collision"
  local terrainPath = "data/generated/maps/0000/neighbors/3/terrain.lua"
  files["data/generated/maps/0000/scene.lua"].neighbors = {
    {
      offsetTilesX = 32,
      offsetTilesZ = 0,
      collision = { file = collisionPath },
      terrain = { file = terrainPath },
    },
  }
  files[collisionPath] = truncatedCollision()
  files[terrainPath] = { schema = "g4-terrain-surfaces-v1", plates = {}, source = { bdhcSha1 = "east" } }
  local neighborReleases = 0
  local neighborLoader = {
    load = function()
      return {
        draws = {},
        release = function()
          neighborReleases = neighborReleases + 1
        end,
      }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    neighborLoader = neighborLoader,
  })
  local err = Assert.throws(function()
    loader:load(0)
  end)
  Assert.isTrue(Errors.is(err) and err.code == "COLLISION_BAD_SIZE", "the collision failure propagates")
  Assert.equal(releases[0], 1, "the scene runtime is released")
  Assert.equal(neighborReleases, 1, "the neighbor runtime is released")
  loader:release()
  Assert.equal(releases[0], 1, "scene release stays exactly once")
  Assert.equal(neighborReleases, 1, "neighbor release stays exactly once")
end

-- The field clock entry point: the aggregate map runtime fans one update
-- call out to the central scene runtime and the neighbor runtime.
function T.runtime_map_update_animated_advances_scene_and_neighbor_exactly_once()
  local cache, world, _, _, files = fixture(1)
  local scene = files["data/generated/maps/0000/scene.lua"]
  local collisionPath = "data/generated/maps/0000/neighbors/3/collision.g4collision"
  local terrainPath = "data/generated/maps/0000/neighbors/3/terrain.lua"
  scene.neighbors = {
    {
      offsetTilesX = 32,
      offsetTilesZ = 0,
      collision = { file = collisionPath },
      terrain = { file = terrainPath },
    },
  }
  files[terrainPath] = { schema = "g4-terrain-surfaces-v1", plates = {}, source = { bdhcSha1 = "east" } }
  files[collisionPath] = CollisionFixture.asset(32, 32)
  local sceneCalls, neighborCalls = 0, 0
  local sceneLoader = {
    load = function(_, s)
      return {
        scene = s,
        updateAnimated = function()
          sceneCalls = sceneCalls + 1
        end,
        release = function() end,
      }
    end,
  }
  local neighborLoader = {
    load = function()
      return {
        draws = {},
        updateAnimated = function()
          neighborCalls = neighborCalls + 1
        end,
        release = function() end,
      }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, {
    sceneLoader = sceneLoader,
    neighborLoader = neighborLoader,
  })
  local map = loader:load(0)
  map:updateAnimated()
  Assert.equal(sceneCalls, 1, "one aggregate call advances the central scene runtime exactly once")
  Assert.equal(neighborCalls, 1, "one aggregate call advances the neighbor runtime exactly once")
  map:updateAnimated()
  Assert.equal(sceneCalls, 2, "each aggregate call advances the central scene runtime exactly once")
  Assert.equal(neighborCalls, 2, "each aggregate call advances the neighbor runtime exactly once")
  map:release()
  loader:release()
end

-- A simulation-only map runtime has no presentation runtimes; the aggregate
-- clock entry stays exposed and must be a safe no-op (headless field
-- behavior preserved).
function T.simulation_only_runtime_exposes_a_safe_update_animated()
  local cache, world = fixture(1)
  local loader = FieldMapLoader.new(cache, world)
  local map = loader:load(0)
  Assert.isTrue(
    type(map.updateAnimated) == "function",
    "the non-presentation runtime still exposes the aggregate clock"
  )
  map:updateAnimated()
  map:updateAnimated()
  loader:release()
end

-- The neighbor loader receives the central scene's textureSrt clip: the one
-- area animation applies to the central terrain and all displayed neighbor
-- cells, so the aggregate must pass the scene field through on the neighbor
-- load.
function T.neighbor_loader_receives_the_central_scene_texture_srt_clip()
  local cache, world, _, _, files = fixture(1)
  local scene = files["data/generated/maps/0000/scene.lua"]
  local collisionPath = "data/generated/maps/0000/neighbors/3/collision.g4collision"
  local terrainPath = "data/generated/maps/0000/neighbors/3/terrain.lua"
  scene.neighbors = {
    {
      offsetTilesX = 32,
      offsetTilesZ = 0,
      collision = { file = collisionPath },
      terrain = { file = terrainPath },
    },
  }
  files[terrainPath] = { schema = "g4-terrain-surfaces-v1", plates = {}, source = { bdhcSha1 = "east" } }
  files[collisionPath] = CollisionFixture.asset(32, 32)
  local clip = {
    id = "area00_ani",
    name = "area00_ani",
    category = "material",
    kind = "texsrt",
    frameCount = 360,
    tracks = {},
    semanticNames = {},
    compiled = { targets = {} },
  }
  scene.terrainAnimations = { textureSrt = clip }
  local received
  local neighborLoader = {
    load = function(_, _, opts)
      received = opts
      return { draws = {}, release = function() end }
    end,
  }
  local loader = FieldMapLoader.new(cache, world, { neighborLoader = neighborLoader })
  loader:load(0)
  Assert.notNil(received, "the neighbor loader receives the central scene's textureSrt clip")
  Assert.equal(received.textureSrt, clip, "the passed clip is the central scene's terrain animation")
  loader:release()
end

return { tests = T }
