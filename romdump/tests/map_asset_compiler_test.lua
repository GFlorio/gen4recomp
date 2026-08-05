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

function T.exports_compiler_version()
  Assert.equal(MapAssetCompiler.COMPILER_VERSION, "map-compiler-v13")
end

function T.compile_requires_romfs_shaped_object()
  local err = Assert.throws(function() MapAssetCompiler.compile({}, "x") end)
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
      textureName = "embedded_tex", paletteName = "embedded_pal", origHeight = 8,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
      embeddedTex0 = Tex0Fixture.block({
        textures = { "embedded_tex" }, palettes = { "embedded_pal" } }),
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
      untextured = true, triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } } }),
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
  Assert.isNil(bundle.scene.source.buildingTexture)
  Assert.isNil(bundle.dependencies.buildingTextureMemberSha1)
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
  Assert.equal(bundle.unresolvedMaterials[1].source,
    "building_textures member " .. MapRomFixture.BUILDING_TEXTURE_PACK_ID)
end

function T.a_fully_resolved_map_reports_nothing_unresolved()
  Assert.deepEqual(assert(compile()).unresolvedMaterials, {})
end

function T.records_the_building_pack_in_dependencies_and_scene_source()
  local bundle = assert(compile())
  Assert.equal(bundle.scene.source.buildingTexture.alias, "building_textures")
  Assert.equal(bundle.scene.source.buildingTexture.memberId,
    MapRomFixture.BUILDING_TEXTURE_PACK_ID)
  Assert.equal(bundle.scene.source.buildingTexture.sha1,
    bundle.dependencies.buildingTextureMemberSha1)
  Assert.equal(bundle.dependencies.buildingTextureMemberId,
    MapRomFixture.BUILDING_TEXTURE_PACK_ID)
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

return T
