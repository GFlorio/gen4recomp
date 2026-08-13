-- ROM-conformance corpus-safety census for the door-ownership bound: MapProps
-- assembly resolves each door tile to the placement whose pivot is nearest,
-- and a tile whose nearest pivot exceeds MAX_DOOR_PIVOT_DISTANCE_TILES must
-- raise MAP_PROP_UNCOVERED_DOOR instead of silently resolving a far-away
-- building. The bound is corpus-backed, so the census verifies over the whole
-- derived cache -- the exact scene descriptors and permission grids the
-- production loader assembles -- that every real door tile's nearest-pivot
-- distance stays within the constant: a bound that rejects any real door
-- breaks real map loads. The census asserts coverage and the bound relation
-- only, never the distance outcome.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local DoorTiles = require("libs.engine.src.DoorTiles")
local FieldGrid = require("libs.engine.src.FieldGrid")
local MapProps = require("libs.engine.src.MapProps")

local T = {
  metadata = {
    layer = "rom",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "door", "census" },
  },
  tests = {},
}

-- The nearest-pivot facts for one map's door tiles, computed with the exact
-- MapProps arithmetic (squared distance over the transform translation vs
-- the FieldGrid tile centre).
local function doorFacts(scene, grid)
  local placements = scene.buildingInstances or {}
  local out = { tiles = 0, uncovered = 0, maxNearestSq = 0 }
  for _, tile in ipairs(DoorTiles.fromGrid(grid)) do
    out.tiles = out.tiles + 1
    local wx, wz = FieldGrid.tileCenterToWorld(tile.x, tile.z)
    local best
    for _, inst in ipairs(placements) do
      local dx, dz = inst.transform[13] - wx, inst.transform[15] - wz
      local distance = dx * dx + dz * dz
      if not best or distance < best then
        best = distance
      end
    end
    if not best then
      out.uncovered = out.uncovered + 1
    else
      out.maxNearestSq = math.max(out.maxNearestSq, best)
    end
  end
  return out
end

-- One pass over the whole map catalog of every ready version whose derived
-- cache is present; every postcondition is asserted against the same census
-- result. A version without a ready dump or cache is recorded and excluded
-- (the declared derived_cache capability makes a cold cache a loud skip at
-- the runner, never a silent pass here).
function T.tests.real_door_tiles_stay_within_the_corpus_backed_bound(context)
  local runnable = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cache = CacheFs.forVersion(versionId)
      if cache:exists("data/generated/maps", "directory") then
        runnable[#runnable + 1] = { versionId = versionId, cache = cache }
      end
    end
  end
  if #runnable == 0 then
    context:skip("no ready version with a derived cache")
  end

  for _, entry in ipairs(runnable) do
    local versionId = entry.versionId
    local cache = entry.cache
    local world = assert(cache:loadLua(MapAssetCache.worldPath()), versionId .. ": world manifest is loadable")
    local maps = world.maps
    assert(type(maps) == "table", versionId .. ": world manifest carries the map list")

    local sceneCount = 0
    local doorMaps = 0
    local totalTiles = 0
    local uncovered = 0
    local maxNearestSq = 0
    for _, map in ipairs(maps) do
      local dir = MapAssetCache.mapDir(map.id)
      if cache:exists(dir .. "/complete") then
        sceneCount = sceneCount + 1
        local scene = assert(cache:loadLua(dir .. "/scene.lua"), "scene " .. map.id .. " is loadable")
        local collisionBytes = assert(cache:read(MapAssetCache.collisionPath(map.id)), "collision asset readable")
        local grid = assert(CollisionGridAsset.decode(collisionBytes, "map " .. map.id))
        local facts = doorFacts(scene, CollisionGrid.new(grid))
        if facts.tiles > 0 then
          doorMaps = doorMaps + 1
          totalTiles = totalTiles + facts.tiles
          uncovered = uncovered + facts.uncovered
          maxNearestSq = math.max(maxNearestSq, facts.maxNearestSq)
        end
      end
    end

    -- Coverage: the census really enumerated the corpus's door maps.
    Assert.isTrue(sceneCount > 0, versionId .. ": the census reached ready maps")
    Assert.isTrue(doorMaps > 0, versionId .. ": the census found door maps")
    Assert.isTrue(totalTiles > 0, versionId .. ": the census found door tiles")
    -- No real door tile is uncovered today: every enumerated door tile has
    -- at least one placement (the distance bound is the only new rejector).
    Assert.equal(uncovered, 0, versionId .. ": no real door tile lacks a placement")

    -- The corpus-backed maximum door distance: the production constant must
    -- exist and must not reject any real door tile.
    local bound = MapProps.MAX_DOOR_PIVOT_DISTANCE_TILES
    Assert.notNil(bound, versionId .. ": MAX_DOOR_PIVOT_DISTANCE_TILES must exist on MapProps (corpus-backed bound)")
    Assert.isTrue(bound > 0 and bound == bound and bound ~= math.huge, "the bound is a finite positive number")
    local maxNearest = math.sqrt(maxNearestSq)
    Assert.isTrue(
      maxNearest <= bound,
      string.format(
        "%s: real door tile nearest-pivot distance %.4f tiles exceeds the bound %.4f (census: %d door maps, %d tiles)",
        versionId,
        maxNearest,
        bound,
        doorMaps,
        totalTiles
      )
    )
  end
end

return T
