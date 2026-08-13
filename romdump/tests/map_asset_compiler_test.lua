-- MapAssetCompiler: constant surface, and the type-directed texture routing a
-- full compile performs. HGSS binds an ordinary placed building to the area's
-- external building texture pack (NARC 0x46) and never uploads that model's own
-- embedded TEX0; terrain binds to the area's map texture pack (NARC 0x2C). Both
-- routes are exercised with deliberately disjoint pack contents so a model bound
-- to the wrong pack cannot resolve by accident -- which shows up as a reported
-- unresolved material drawing untextured, as it would on the DS, not as a failure.

local Assert = require("tests.support.Assert")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapRomFixture = require("tests.support.MapRomFixture")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Tex0Fixture = require("tests.support.Tex0Fixture")

local T = {}

local function compile(opts)
  local romFs = MapRomFixture.build(opts)
  local bundle, err = MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL)
  return bundle, err, romFs
end

local function onlyModel(bundle)
  local found
  for _, model in pairs(bundle.models) do
    assert(not found, "expected exactly one building model")
    found = model
  end
  return assert(found, "expected one building model")
end

function T.compile_requires_romfs_shaped_object()
  local err = Assert.throws(function()
    MapAssetCompiler.compile({}, "x")
  end)
  Assert.isTrue(tostring(err):find("RomFs") ~= nil, "error mentions RomFs")
end

function T.building_binds_to_the_area_building_pack_without_embedded_tex0()
  local bundle = assert(compile())
  local model = onlyModel(bundle)
  Assert.equal(model.memberId, MapRomFixture.BUILDING_MODEL_MEMBER_ID)
  Assert.notNil(model.materials[1].texture)
  Assert.equal(#bundle.scene.buildingInstances, 1)
  Assert.equal(bundle.scene.buildingInstances[1].modelKey, model.key)
end

function T.building_ignores_its_own_embedded_tex0()
  -- The embedded TEX0 is the ONLY place the requested names exist; the external
  -- building pack has different ones. HGSS would fail to resolve them too, so a
  -- compiler that silently fell back to the embedded block would pass here.
  local bundle = assert(compile({
    buildingModel = NsbmdFixture.build({
      textureName = "embedded_tex",
      paletteName = "embedded_pal",
      origHeight = 8,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
      embeddedTex0 = Tex0Fixture.block({
        textures = { "embedded_tex" },
        palettes = { "embedded_pal" },
      }),
    }),
  }))
  Assert.isNil(onlyModel(bundle).materials[1].texture)
  Assert.equal(#bundle.unresolvedMaterials, 1)
  Assert.equal(bundle.unresolvedMaterials[1].role, "building")
  Assert.equal(bundle.unresolvedMaterials[1].name, "embedded_tex")
end

function T.building_with_no_named_bindings_compiles_as_a_no_op()
  -- Building model 38 (`leage_o03`) has no embedded TEX0 and no named material
  -- bindings; Nitro's bind loops run zero times and succeed.
  local bundle = assert(compile({
    buildingModel = NsbmdFixture.build({
      untextured = true,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
    }),
  }))
  local model = onlyModel(bundle)
  Assert.equal(#model.batches, 2)
  Assert.isNil(model.materials[1].texture)
end

function T.a_map_with_no_placed_buildings_never_opens_the_building_pack()
  -- Areas with no placed buildings point buildingTexturePackId at one of the
  -- four-byte placeholder members of building_textures, which is not a Nitro
  -- file. HGSS never extracts a TEX0 it has no models to bind, so neither does
  -- the compiler.
  local bundle = assert(compile({ buildings = "", buildingPack = false }))
  Assert.deepEqual(bundle.models, {})
  Assert.equal(#bundle.scene.buildingInstances, 0)
  Assert.isNil(bundle.dependencies.buildingTextureMemberSha1)
  Assert.isNil(bundle.scene.source, "source identity lives in the dependency record")
end

function T.terrain_does_not_see_building_textures()
  local bundle = assert(compile({
    mapPack = { textures = { "unrelated" }, palettes = { "unrelated_pal" } },
  }))
  Assert.equal(#bundle.unresolvedMaterials, 1)
  local entry = bundle.unresolvedMaterials[1]
  Assert.equal(entry.role, "map")
  Assert.equal(entry.name, MapRomFixture.MAP_TEXTURE)
  Assert.equal(entry.modelArchive, "land_data")
  Assert.equal(entry.modelMemberId, MapRomFixture.LAND_DATA_MEMBER_ID)
end

function T.buildings_do_not_see_map_textures()
  local bundle = assert(compile({
    buildingPack = { textures = { "unrelated" }, palettes = { "unrelated_pal" } },
  }))
  Assert.equal(#bundle.unresolvedMaterials, 1)
  Assert.equal(bundle.unresolvedMaterials[1].role, "building")
  Assert.isNil(onlyModel(bundle).materials[1].texture)
end

function T.an_unresolved_material_names_the_source_that_was_checked()
  local bundle = assert(compile({
    buildingPack = { textures = { "unrelated" }, palettes = { "unrelated_pal" } },
  }))
  Assert.equal(
    bundle.unresolvedMaterials[1].source,
    "building_textures member " .. MapRomFixture.BUILDING_TEXTURE_PACK_ID
  )
end

function T.a_fully_resolved_map_reports_nothing_unresolved()
  Assert.deepEqual(assert(compile()).unresolvedMaterials, {})
end

function T.records_the_building_pack_in_dependencies()
  local bundle = assert(compile())
  Assert.equal(bundle.dependencies.buildingTextureMemberId, MapRomFixture.BUILDING_TEXTURE_PACK_ID)
  Assert.notNil(bundle.dependencies.buildingTextureMemberSha1, "the building pack bytes are hashed")
  Assert.isNil(bundle.scene.source, "source identity lives in the dependency record")
end

function T.changing_the_building_texture_member_changes_the_marker()
  local base = assert(compile())
  local moved = assert(compile({ buildingTexturePackId = 9 }))
  Assert.isTrue(base.marker ~= moved.marker, "marker must track the building pack member")

  local repacked = assert(compile({
    buildingPack = {
      textures = { MapRomFixture.BUILDING_TEXTURE, "spare" },
      palettes = { MapRomFixture.BUILDING_PALETTE },
    },
  }))
  Assert.isTrue(base.marker ~= repacked.marker, "marker must track the building pack bytes")
end

function T.compile_is_deterministic()
  local first = assert(compile())
  local second = assert(compile())
  Assert.equal(first.marker, second.marker)
  Assert.equal(onlyModel(first).key, onlyModel(second).key)
end

-- An animated building model whose display list straddles a mid-run matrix
-- boundary compiles into a descriptor batch carrying the per-vertex source
-- provenance (the DS transforms each vertex at submission under the
-- then-current matrix, so the runtime needs both sources and the split to
-- reproduce the bend).
function T.animated_straddling_primitives_serialize_per_vertex_sources()
  local AnimationFixture = require("tests.support.AnimationFixture")

  local bw = require("libs.codec.src.BinaryWriter").new()
  bw:u16(0)
  bw:u16(0)
  bw:u32(0)
  bw:u32(0) -- resource id 0
  for _ = 1, 3 do
    bw:u32(0xFFFFFFFF)
  end
  assert(#bw:tostring() == 0x18)

  -- A quad display list with MTX_RESTORE slot 3 after the first two
  -- vertices: the quad straddles the boundary, so the descriptor batch must
  -- carry { leading = 2, source = "draw" } -- the pre-restore source.
  local NB = require("tests.support.NitroBuilder")
  local vtx16xy = NB.vtx16xy
  local pack = NB.gxPack
  local straddlingQuad = pack({
    { { 0x40, 0x23, 0x23 }, { 1, vtx16xy(0, 0), 0, vtx16xy(1, 0), 0 } },
    { { 0x14 }, { 3 } },
    { { 0x23, 0x23, 0x41 }, { vtx16xy(1, 1), 0, vtx16xy(0, 1), 0 } },
  })

  local romFs = MapRomFixture.build({
    interiorBuildAnimList = { [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = bw:tostring() },
    buildAnim = { [0] = AnimationFixture.jntDoor() },
    -- NsbmdFixture.build's default SBC draws the shape twice; a single
    -- MAT/SHP draw keeps the straddle count at exactly one per shape.
    buildingModel = NsbmdFixture.buildWithSbc(
      string.char(0x06, 0, 0, 0) -- NODEDESC root
        .. string.char(0x02, 0, 1) -- NODE node0 vis
        .. string.char(0x0B) -- POSSCALE
        .. string.char(0x04, 0) -- MAT 0
        .. string.char(0x05, 0) -- SHP 0
        .. string.char(0x01), -- RET
      {
        untextured = true,
        triangle = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, 1 } },
        displayList = straddlingQuad,
      }
    ),
  })
  local bundle = assert(MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL))
  local model = onlyModel(bundle)
  Assert.equal(model.kind, "nitro-dynamic")
  -- The straddling quad's batch carries the per-vertex source split.
  local straddles = {}
  for _, batch in ipairs(model.dynamic.batches) do
    if batch.straddle then
      straddles[#straddles + 1] = batch
    end
  end
  Assert.equal(#straddles, 1)
  Assert.deepEqual(straddles[1].straddle, { leading = 2, source = "draw" })
end

-- The animated cache round trip: compile one animated building model, write
-- the bundle through MapCacheWriter, assert readiness, and load the scene
-- through MapSceneLoader -- the exact boundary the buildcache failure
-- regressed at.
function T.animated_bundle_round_trips_through_writer_readiness_and_loader()
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local MapCacheWriter = require("romdump.src.digest.MapCacheWriter")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
  local AnimationFixture = require("tests.support.AnimationFixture")

  local bw = require("libs.codec.src.BinaryWriter").new()
  bw:u16(0)
  bw:u16(0)
  bw:u32(0)
  bw:u32(0) -- resource id 0
  for _ = 1, 3 do
    bw:u32(0xFFFFFFFF)
  end
  assert(#bw:tostring() == 0x18)
  local romFs = MapRomFixture.build({
    interiorBuildAnimList = { [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = bw:tostring() },
    buildAnim = { [0] = AnimationFixture.jntDoor() },
  })
  local bundle = assert(MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL))
  local model = onlyModel(bundle)
  Assert.equal(model.schema, "g4-model-v2")
  Assert.equal(model.kind, "nitro-dynamic")
  Assert.equal(#model.animations, 1)
  Assert.equal(model.animations[1].name, "door_op")
  Assert.equal(model.animations[1].semanticNames[1], "door.open")

  local c = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = MapCacheWriter.write(c, bundle)
  Assert.isTrue(MapAssetCache.isReady(c, bundle.mapId, marker), "the written map reads ready")
  Assert.isTrue(c:exists(MapAssetCache.modelPath(model.key)), "the model descriptor is on disk")
  -- The model key is content-addressed over the descriptor: a static
  -- compile of the same member would get a different key.
  Assert.isTrue(model.key:match("^indoor:%d+:[0-9a-f]+$") ~= nil, "key embeds the descriptor hash")

  -- The loader builds one animated instance from the written descriptor.
  local scene = assert(c:loadLua(MapAssetCache.mapDir(bundle.mapId) .. "/scene.lua"))
  local meshBuilder = function()
    return { release = function() end }
  end
  local imageBuilder = function()
    return {
      setFilter = function() end,
      setWrap = function() end,
      release = function() end,
    }
  end
  local runtime = MapSceneLoader.load(c, scene, { meshBuilder = meshBuilder, imageBuilder = imageBuilder })
  Assert.equal(runtime.stats.animatedInstances, 1)
  local instance = runtime.animatedInstances[1]
  -- The door clip is scripted (door role, not ambient): the play handle
  -- drives it and the compiled clip advances.
  local handle = instance:play("door.open")
  Assert.equal(handle.clip.name, "door_op")
  runtime:updateAnimated()
  Assert.equal(handle.player.frameFx, 4096, "the compiled clip advances")
end

return { tests = T }
