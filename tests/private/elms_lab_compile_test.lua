-- Private target test: deterministic derived compilation of Professor Elm's Lab
-- 1F (map 61) against a real HGSS dump. Compiling twice from the unchanged raw
-- dump must produce byte-identical scene, mesh, and texture output; the result
-- must be complete (every placed indoor model, a 2048-byte permission grid) and
-- report ready; and an injected write failure must leave no completion marker
-- and spare the raw-dump marker. Runs only via --test-private.

local Assert = require("tests.support.Assert")
local CacheFs = require("src.import.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCompiler = require("src.import.MapAssetCompiler")
local MapCacheWriter = require("src.import.MapCacheWriter")
local MapAssetCache = require("src.core.MapAssetCache")
local SceneMesh = require("src.render.SceneMesh")
local PermissionGrid = require("src.data.PermissionGrid")
local CollisionGrid = require("src.world.CollisionGrid")
local DebugPlayer = require("src.world.DebugPlayer")

local T = {}
local SYMBOL = "MAP_NEW_BARK_ELMS_LAB_1F"
local MAP_ID = 61

local function compileInto(romFs, version)
  local c = CacheFs.forVersion(version, FakeCache.new())
  local bundle = assert(MapAssetCompiler.compile(romFs, SYMBOL))
  local marker = MapCacheWriter.write(c, bundle)
  return c, bundle, marker
end

local function sortedKeys(t)
  local k = {}
  for x in pairs(t) do k[#k + 1] = x end
  table.sort(k)
  return k
end

function T.gate5_deterministic_bytes(romFs, version)
  local c1, b1 = compileInto(romFs, version)
  local c2, b2 = compileInto(romFs, version)
  local dir = MapAssetCache.mapDir(MAP_ID)

  Assert.equal(b1.marker, b2.marker)
  Assert.equal(c1:read(dir .. "/scene.lua"), c2:read(dir .. "/scene.lua"))
  Assert.equal(c1:read(dir .. "/dependencies.lua"), c2:read(dir .. "/dependencies.lua"))
  Assert.deepEqual(sortedKeys(b1.meshes), sortedKeys(b2.meshes))
  Assert.deepEqual(sortedKeys(b1.textures), sortedKeys(b2.textures))

  for sha in pairs(b1.meshes) do
    Assert.equal(c1:read(MapAssetCache.geometryPath(sha)), c2:read(MapAssetCache.geometryPath(sha)))
  end
  for sha in pairs(b1.textures) do
    Assert.equal(c1:read(MapAssetCache.texturePath(sha)), c2:read(MapAssetCache.texturePath(sha)))
  end
  print(string.format("  [elms_lab] compiled %d meshes, %d textures, %d building models deterministically",
    #sortedKeys(b1.meshes), #sortedKeys(b1.textures), #sortedKeys(b1.models)))
end

function T.gate5_completeness_and_ready(romFs, version)
  local c, bundle, marker = compileInto(romFs, version)
  Assert.isTrue(MapAssetCache.isReady(c, MAP_ID, marker), "cache reports ready")
  Assert.equal(#c:read(MapAssetCache.mapDir(MAP_ID) .. "/permissions.bin"), 2048)
  Assert.equal(bundle.scene.schema, "g4-map-scene-v2")

  Assert.equal(#sortedKeys(bundle.models), 9)      -- unique indoor building models
  Assert.equal(#bundle.scene.buildingInstances, 15) -- placed instances

  -- Polygon state moved from material records to batch records in slice 4.
  for _, m in ipairs(bundle.scene.materials) do
    Assert.isNil(m.alphaMode)
    Assert.isNil(m.alphaCutoff)
    Assert.isNil(m.cullMode)
  end
  for _, b in ipairs(bundle.scene.mapBatches) do
    Assert.notNil(b.alphaClass)
    Assert.notNil(b.cullMode)
    Assert.notNil(b.polygonAlpha)
  end
  Assert.notNil(bundle.scene.lighting)
  Assert.notNil(bundle.scene.lighting.records)

  -- Every building instance references a compiled model descriptor written to disk.
  for _, inst in ipairs(bundle.scene.buildingInstances) do
    Assert.notNil(bundle.models[inst.modelKey], "instance references a compiled model: " .. inst.modelKey)
    Assert.isTrue(c:exists(MapAssetCache.modelPath(inst.modelKey)), "model descriptor on disk")
  end
  -- Every map batch references a mesh present on disk.
  for _, b in ipairs(bundle.scene.mapBatches) do
    Assert.isTrue(c:exists(b.geometry), "map mesh on disk: " .. b.geometry)
  end
end

-- Slice 6: the selected field-light profile is source-hashed and its records
-- serialize deterministically; compiling twice yields identical lighting data.
function T.gate6_lighting_profile_deterministic(romFs, version)
  local _, b1 = compileInto(romFs, version)
  local _, b2 = compileInto(romFs, version)
  local l1, l2 = b1.scene.lighting, b2.scene.lighting
  Assert.equal(l1.lightTypeRaw, l2.lightTypeRaw)
  Assert.equal(l1.profileId, l2.profileId)
  Assert.equal(l1.sourcePath, l2.sourcePath)
  Assert.equal(l1.sourceSha1, l2.sourceSha1)
  Assert.equal(#l1.records, #l2.records)
  for i = 1, #l1.records do
    Assert.deepEqual(l1.records[i], l2.records[i])
  end
  -- Profile source is hashed into cache dependencies.
  Assert.equal(b1.dependencies.fieldLightSourceSha1, l1.sourceSha1)
  Assert.equal(b2.dependencies.fieldLightSourceSha1, l2.sourceSha1)
end

-- Regression: DS texcoords are in texel units and must be normalized to
-- [0,1] by the bound texture size. Before the fix the healing machine (64px
-- texture) carried UVs up to 63 and clamped to a black edge texel. Elm's models
-- are all clamp/single-texture, so no legitimate UV should approach the raw
-- texel magnitudes; bound them well under any texel range.
function T.gate6_uvs_are_normalized(romFs, version)
  local _, bundle = compileInto(romFs, version)
  local maxUV = 0
  for _, batch in pairs(bundle.meshes) do
    for _, vtx in ipairs(batch.vertices) do
      maxUV = math.max(maxUV, math.abs(vtx.u), math.abs(vtx.v))
    end
  end
  Assert.isTrue(maxUV <= 8, "normalized UVs stay small, got max " .. maxUV)
end

-- Cache-only restart. After a successful compile the map loads and
-- traverses from the derived cache alone -- no ROM, and geometry comes from
-- baked G4M2 batches rather than a re-parsed NSBMD. Modelled by building into an
-- in-memory backend, then reopening a fresh CacheFs over the same backend and
-- using nothing but cache reads below the "restart" line.
function T.gate8_cache_only_restart(romFs, version)
  local backend = FakeCache.new()
  local marker
  do
    local c = CacheFs.forVersion(version, backend)
    local bundle = assert(MapAssetCompiler.compile(romFs, SYMBOL))
    marker = MapCacheWriter.write(c, bundle)
  end

  -- ---- restart: everything below reads only the cache ----
  local cache = CacheFs.forVersion(version, backend)
  Assert.isTrue(MapAssetCache.isReady(cache, MAP_ID, marker), "cache is ready without the ROM")

  local dir = MapAssetCache.mapDir(MAP_ID)
  local scene = assert(cache:loadLua(dir .. "/scene.lua"))

  -- Geometry loads as baked G4M2 batches from the derived-asset subtree; the map
  -- never re-parses NSBMD/NSBTX at load, and no reference escapes the cache.
  for _, b in ipairs(scene.mapBatches) do
    Assert.isTrue(b.geometry:find("^assets/generated/") ~= nil, "geometry is a derived asset: " .. b.geometry)
    local decoded = SceneMesh.decode(assert(cache:read(b.geometry), "mesh present: " .. b.geometry))
    Assert.isTrue(decoded.vertexCount > 0, "baked mesh has vertices")
  end
  for _, inst in ipairs(scene.buildingInstances) do
    Assert.isTrue(cache:exists(MapAssetCache.modelPath(inst.modelKey)), "model descriptor cached")
  end

  -- Load and traverse from the cached permission grid alone.
  local perms = assert(cache:read(dir .. "/permissions.bin"))
  Assert.equal(#perms, 2048)
  local collision = CollisionGrid.new(assert(PermissionGrid.decode(perms)), {
    worldOriginX = scene.matrix.worldOriginX, worldOriginZ = scene.matrix.worldOriginZ })
  local player = DebugPlayer.new(collision, { x = 4, z = 13 })
  Assert.isTrue(player:tryStep("south"), "steps onto the exit warp tile from cache-only data")
  Assert.equal(player:status().localZ, 14)
end

function T.gate5_injected_failure_leaves_no_marker(romFs, version)
  local backend = FakeCache.new()
  local orig = backend.write
  backend.write = function(self, path, data)
    if path:find("scene.lua", 1, true) then error("injected write failure") end
    return orig(self, path, data)
  end
  local c = CacheFs.forVersion(version, backend)
  c:write("rom-dump.complete", "raw-owned-by-previous-sprint")

  local bundle = assert(MapAssetCompiler.compile(romFs, SYMBOL))
  Assert.isTrue(not pcall(MapCacheWriter.write, c, bundle), "write raises")
  Assert.isTrue(not c:exists(MapAssetCache.mapDir(MAP_ID) .. "/complete"), "no false marker")
  Assert.isTrue(c:exists("rom-dump.complete"), "raw-dump marker preserved")
end

return T
