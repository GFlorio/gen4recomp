-- TerrainAnimationCompiler: contract tests for the map-scoped compiler that
-- annotates fldtanime-matched terrain materials (`data/fldtanime.narc` in
-- pret/pokeheartgold, dump alias `field_texture_animations`) with textureSwap
-- records, decodes alternate frames from the replacement member's texels
-- under the base material's palette, compiles the area NSBTA selected by the
-- area record's dynamicTextureType (archive `field_area_texture_srt`), and
-- accumulates deterministic dependency hashes. The compiler is exercised
-- through ModelAssetCompiler.compileModel with `terrainAnimations` in the
-- context, the production route, then through compileTextureSrt() and
-- dependencies().

local Assert = require("tests.support.Assert")
local AnimationFixture = require("tests.support.AnimationFixture")
local BinaryReader = require("libs.codec.src.BinaryReader")
local FieldTexAnimFixture = require("tests.support.FieldTextureAnimationFixture")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapRomFixture = require("tests.support.MapRomFixture")
local ModelAssetCompiler = require("romdump.src.digest.ModelAssetCompiler")
local NitroAnimation = require("romdump.src.digest.nitro.NitroAnimation")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local NsbtaClipCompiler = require("romdump.src.digest.NsbtaClipCompiler")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")
local TF = require("tests.support.TextureFixtures")
local Tex0Fixture = require("tests.support.Tex0Fixture")
local TerrainAnimationCompiler = require("romdump.src.digest.TerrainAnimationCompiler")

local T = {}

local MAP_ID = MapRomFixture.MAP_ID
local PACK_ID = MapRomFixture.MAP_TEXTURE_PACK_ID
local LAND_MEMBER_ID = MapRomFixture.LAND_DATA_MEMBER_ID

-- Base map texture: 8x8 palette16 whose texels are all index 1, over a
-- palette with distinct colours at indices 1-3 so an alternate frame's texel
-- and palette provenance is observable in the decoded pixels.
local BASE_TEXEL = string.rep(string.char(0x11), 32)
local BASE_PALETTE = { TF.BLACK, TF.RED, TF.GREEN, TF.BLACK }
-- The replacement pack's own palette marks index 2 blue; a compiler that
-- decoded alternates with the replacement palette instead of the base one
-- would produce blue frames and fail the pixel assertions.
local REPLACEMENT_PALETTE = { TF.BLACK, TF.BLUE, TF.BLUE, TF.BLUE }

local FLOWER_TIMELINE = { { 0, 18 }, { 1, 18 }, { 0, 18 }, { 2, 18 } }

local function texels(pattern)
  return string.rep(string.char(pattern), 32)
end

-- A replacement BTX0 member whose dictionary textures, in order, are the
-- swap frames; the palette is deliberately the replacement's own.
local function replacementMember(texelList)
  local textures = {}
  for i, texel in ipairs(texelList) do
    textures[#textures + 1] = { name = "alt" .. i, texel = texel }
  end
  return Tex0Fixture.btx0({
    textures = textures,
    palettes = { { name = "alt_pal", palette = TF.palette(REPLACEMENT_PALETTE) } },
  })
end

local function flowerAnimations()
  return {
    [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = FLOWER_TIMELINE } }),
    [1] = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) }),
  }
end

local function basePack()
  return {
    textures = { { name = "flower01", texel = BASE_TEXEL } },
    palettes = { { name = "map_pal", palette = TF.palette(BASE_PALETTE) } },
  }
end

-- Fixture options that wire the animation defaults: the base pack the map
-- material binds and the fldtanime table plus its replacement member.
local function animationSceneOpts()
  return { mapPack = basePack(), fieldTextureAnimations = flowerAnimations() }
end

-- One decoded terrain model whose material binds `textureName` with the
-- 8x8 fixture texture geometry.
local function terrainModel(opts)
  opts = opts or {}
  local bytes = NsbmdFixture.build({
    modelName = "map0",
    materialName = opts.materialName or "m_flower01",
    textureName = opts.textureName or "flower01",
    paletteName = "map_pal",
    origWidth = 8,
    origHeight = 8,
    triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
  })
  return assert(Nsbmd.decode(bytes, { alias = "land_data", memberId = LAND_MEMBER_ID })).models[1]
end

-- Fixture romFs + decoded map pack + one map-scoped compiler.
local function buildScene(opts)
  opts = opts or {}
  local romFs, members = MapRomFixture.build(opts)
  local pack = assert(Nsbtx.decode(members.map_textures[PACK_ID], { alias = "map_textures", memberId = PACK_ID }))
  local dynamicTextureType = opts.dynamicTextureType
  if dynamicTextureType == nil then
    dynamicTextureType = 0xFFFF
  end
  local compiler = TerrainAnimationCompiler.new(romFs, {
    mapId = MAP_ID,
    dynamicTextureType = dynamicTextureType,
  })
  return { romFs = romFs, members = members, pack = pack, compiler = compiler }
end

-- The full production route: compile one central terrain model through
-- ModelAssetCompiler.compileModel with the terrain compiler attached.
local function compileScene(opts)
  opts = opts or {}
  local scene = buildScene(opts)
  local meshes, textures = {}, {}
  scene.compiled = ModelAssetCompiler.compileModel(terrainModel(opts), scene.pack, meshes, textures, {
    mapId = MAP_ID,
    role = "map",
    textureArchive = "map_textures",
    textureMemberId = PACK_ID,
    modelArchive = "land_data",
    modelMemberId = LAND_MEMBER_ID,
    modelName = "map0",
    terrainAnimations = scene.compiler,
  })
  scene.meshes = meshes
  scene.textures = textures
  return scene
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.equal(err.code, code)
  return err
end

local function textureAsset(path, textures)
  for sha1, asset in pairs(textures) do
    if MapAssetCache.texturePath(sha1) == path then
      return asset
    end
  end
  error("no compiled texture for " .. path)
end

local function solidPixels(r, g, b)
  return string.rep(string.char(r, g, b, 255), 64)
end

-- Matching is by the decoded material's textureName, never its material
-- name: the material is named m_flower01 while the record names the texture
-- flower01.
function T.texture_name_match_annotates_the_terrain_material()
  local scene = assert(compileScene(animationSceneOpts()))
  local material = scene.compiled.materials[1]
  Assert.equal(material.name, "m_flower01")
  Assert.equal(material.textureSwap.name, "flower01")
  Assert.equal(#material.textureSwap.textures, 3)
  Assert.deepEqual(material.textureSwap.timeline, {
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 1, durationTicks = 18 },
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 2, durationTicks = 18 },
  })
  Assert.equal(material.textureSwap.textures[1], material.texture)
end

function T.an_unmatched_material_stays_static_and_reads_no_replacement_member()
  -- The table names flower01 and its replacement member 1, which the fixture
  -- does NOT provide: any read of it would trip the fixture's missing-member
  -- assert. The material binds map_tex, which no record names, so it must
  -- compile unannotated without touching the archive.
  local tableMember = FieldTexAnimFixture.member({ { name = "flower01", timeline = FLOWER_TIMELINE } })
  local scene = assert(compileScene({
    textureName = "map_tex",
    fieldTextureAnimations = { [0] = tableMember },
  }))
  local material = scene.compiled.materials[1]
  Assert.isNil(material.textureSwap)
  Assert.notNil(material.texture, "the unmatched material still binds its base texture")
  local deps = scene.compiler:dependencies()
  Assert.deepEqual(deps.fieldTextureAnimations.memberSha1s, {})
  Assert.equal(deps.fieldTextureAnimations.tableSha1, Hashing.sha1hex(tableMember))
end

function T.alters_decode_with_the_base_palette_and_replacement_texels()
  local scene = assert(compileScene(animationSceneOpts()))
  local material = scene.compiled.materials[1]
  -- The base material decodes texel index 1 -> the base palette's red.
  Assert.equal(textureAsset(material.texture, scene.textures).pixels, solidPixels(255, 0, 0))
  -- Frame 1 is texel index 2 with the BASE palette (green at index 2); the
  -- replacement pack's own palette is blue at index 2 and must never be used.
  Assert.equal(textureAsset(material.textureSwap.textures[2], scene.textures).pixels, solidPixels(0, 255, 0))
  -- Frame 2 is texel index 3 -> the base palette's black.
  Assert.equal(textureAsset(material.textureSwap.textures[3], scene.textures).pixels, solidPixels(0, 0, 0))
end

function T.frame_zero_deduplicates_to_the_material_texture()
  local scene = assert(compileScene(animationSceneOpts()))
  local material = scene.compiled.materials[1]
  local swap = material.textureSwap
  Assert.equal(swap.textures[swap.timeline[1].textureIndex + 1], material.texture)
  -- The base image plus the two distinct alternates: frame 0 shares the base.
  local count = 0
  for _ in pairs(scene.textures) do
    count = count + 1
  end
  Assert.equal(count, 3)
end

function T.repeated_schedule_indices_do_not_duplicate_texture_paths()
  local scene = assert(compileScene(animationSceneOpts()))
  local swap = scene.compiled.materials[1].textureSwap
  -- The four-entry schedule repeats index 0; the path list holds the three
  -- replacement dictionary textures once each, in dictionary order.
  Assert.equal(#swap.textures, 3)
  Assert.isTrue(swap.textures[1] ~= swap.textures[2])
  Assert.isTrue(swap.textures[2] ~= swap.textures[3])
  Assert.isTrue(swap.textures[1] ~= swap.textures[3])
end

function T.an_out_of_range_schedule_index_fails()
  local err = throwsCode("TERRAIN_ANIM_TEXTURE_INDEX_OUT_OF_RANGE", function()
    return compileScene({
      mapPack = basePack(),
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 3, 18 } } } }),
        [1] = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) }),
      },
    })
  end)
  Assert.isTrue(tostring(err.message):find("flower01") ~= nil, "the error names the record")
end

function T.incompatible_replacement_textures_fail()
  local cases = {
    width = { { name = "alt1", format = 3, width = 16, height = 8 } },
    height = { { name = "alt1", format = 3, width = 8, height = 16 } },
    format = { { name = "alt1", format = 2, width = 8, height = 8 } },
    texel = { { name = "alt1", texel = string.rep("\0", 16) } },
  }
  for name, textures in pairs(cases) do
    local err = Assert.throws(function()
      return compileScene({
        mapPack = basePack(),
        fieldTextureAnimations = {
          [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 18 } } } }),
          -- Only the texel-length case ends the pack at the texel region; the
          -- others carry a full palette block.
          [1] = Tex0Fixture.btx0({
            textures = textures,
            palettes = name == "texel" and {} or { { name = "alt_pal", palette = TF.palette(REPLACEMENT_PALETTE) } },
          }),
        },
      })
    end, "incompatibility case " .. name)
    Assert.equal(err.code, "TERRAIN_ANIM_TEXTURE_INCOMPATIBLE")
  end

  -- Auxiliary/index-data length: the base is compressed4x4 with an 8-byte
  -- control-word region; the replacement is compressed4x4 with a 4-byte one.
  local err = Assert.throws(function()
    return compileScene({
      mapPack = {
        textures = { { name = "flower01", format = 5, plttIdx = string.rep("\0", 8) } },
        palettes = { { name = "map_pal", palette = TF.palette(BASE_PALETTE) } },
      },
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 18 } } } }),
        [1] = Tex0Fixture.btx0({
          textures = { { name = "alt1", format = 5, plttIdx = string.rep("\0", 4) } },
          palettes = {},
        }),
      },
    })
  end, "auxiliary-data incompatibility")
  Assert.equal(err.code, "TERRAIN_ANIM_TEXTURE_INCOMPATIBLE")
end

function T.dynamic_texture_type_ffff_reads_no_nsbta_member()
  -- The fixture provides no field_area_texture_srt archive at all, so any
  -- read would trip the missing-archive assert; the no-animation selection
  -- must compile without touching it.
  local scene = assert(compileScene({ dynamicTextureType = 0xFFFF }))
  Assert.equal(scene.compiler:compileTextureSrt(), false)
  Assert.equal(scene.compiler:dependencies().terrainTextureSrt, false)
end

function T.a_selected_nsbta_compiles_the_existing_clip_shape_without_source_fields()
  local srtBytes = AnimationFixture.srtWater()
  local scene = assert(compileScene({
    dynamicTextureType = 0,
    fieldAreaTextureSrt = { [0] = srtBytes },
  }))
  local clip = scene.compiler:compileTextureSrt()
  assert(clip ~= false, "a selected NSBTA must compile a clip")
  Assert.equal(clip.name, "en_sp1")
  Assert.equal(clip.id, "en_sp1")
  Assert.equal(clip.category, "material")
  Assert.equal(clip.kind, "texsrt")
  Assert.equal(clip.frameCount, 8)
  Assert.deepEqual(clip.tracks, { { target = "en_sp1_3", targetIndex = 0 } })
  Assert.deepEqual(clip.semanticNames, {})
  Assert.isNil(clip.source, "the scene clip carries no physical source provenance")
  -- The compiled payload is exactly the existing NsbtaClipCompiler shape.
  local decoded = assert(NitroAnimation.decode(srtBytes))
  local anim = assert(decoded.animations[1])
  local reader = BinaryReader.new(decoded.bytes, "sec")
  local expected = NsbtaClipCompiler.compilePayload(anim.resource, reader, #decoded.bytes, anim.name)
  Assert.deepEqual(clip.compiled, expected)
  -- The selected member is recorded as producer provenance in the deps.
  Assert.deepEqual(scene.compiler:dependencies().terrainTextureSrt, {
    memberId = 0,
    sha1 = Hashing.sha1hex(srtBytes),
  })
end

function T.an_invalid_selected_nsbta_member_fails()
  local function srtErr(dynamicTextureType, fieldAreaTextureSrt)
    return Assert.throws(function()
      local scene = compileScene({ dynamicTextureType = dynamicTextureType, fieldAreaTextureSrt = fieldAreaTextureSrt })
      return scene.compiler:compileTextureSrt()
    end)
  end
  -- Out of range: the archive has one member, the area selects member 5.
  Assert.equal(srtErr(5, { [0] = AnimationFixture.srtWater() }).code, "TERRAIN_ANIM_SRT_MEMBER_OUT_OF_RANGE")
  -- Wrong Nitro format: a BTX0 member is not an animation resource.
  Assert.equal(
    srtErr(0, { [0] = Tex0Fixture.btx0({ textures = { "x" }, palettes = { "y" } }) }).code,
    "ANM_UNKNOWN_FILE_MAGIC"
  )
  -- A valid animation of the wrong kind: NSBCA is not the NSBTA the area
  -- texture-SRT selection requires.
  Assert.equal(srtErr(0, { [0] = AnimationFixture.jntDoor() }).code, "TERRAIN_ANIM_SRT_NOT_NSBTA")
  -- An empty animation set cannot drive a clip.
  Assert.equal(srtErr(0, { [0] = AnimationFixture.srtMember({}) }).code, "TERRAIN_ANIM_EMPTY_SET")
  -- More than one animation in the selected member is ambiguous.
  Assert.equal(srtErr(0, { [0] = AnimationFixture.srtMember({ "a", "b" }) }).code, "TERRAIN_ANIM_AMBIGUOUS_SET")
end

function T.dependencies_carry_the_table_hash_and_only_used_member_hashes()
  local tableMember = FieldTexAnimFixture.member({
    { name = "flower01", timeline = FLOWER_TIMELINE },
    { name = "flower02", timeline = { { 0, 12 }, { 1, 12 } } },
    { name = "flower03", timeline = { { 0, 6 } } },
  })
  local member1 = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) })
  local member2 = replacementMember({ BASE_TEXEL, texels(0x22) })
  local member3 = replacementMember({ BASE_TEXEL }) -- present but never used
  local scene = buildScene({
    mapPack = {
      textures = {
        { name = "flower01", texel = BASE_TEXEL },
        { name = "flower02", texel = BASE_TEXEL },
      },
      palettes = { { name = "map_pal", palette = TF.palette(BASE_PALETTE) } },
    },
    fieldTextureAnimations = {
      [0] = tableMember,
      [1] = member1,
      [2] = member2,
      [3] = member3,
    },
  })
  local function compileModel(textureName, role)
    local meshes, textures = {}, {}
    local compiled =
      ModelAssetCompiler.compileModel(terrainModel({ textureName = textureName }), scene.pack, meshes, textures, {
        mapId = MAP_ID,
        role = role,
        textureArchive = "map_textures",
        textureMemberId = PACK_ID,
        modelArchive = "land_data",
        modelMemberId = LAND_MEMBER_ID,
        modelName = "map0",
        terrainAnimations = scene.compiler,
      })
    return compiled
  end
  -- The central terrain matches flower02 (member 2); the neighbor chunk
  -- matches flower01 (member 1). Both compile into one map-scoped compiler,
  -- so the recorded member list is sorted by member id: 1 before 2.
  local central = compileModel("flower02", "map")
  local neighbor = compileModel("flower01", "neighbor")
  Assert.equal(central.materials[1].textureSwap.name, "flower02")
  Assert.equal(neighbor.materials[1].textureSwap.name, "flower01")

  local deps = scene.compiler:dependencies()
  Assert.deepEqual(deps.fieldTextureAnimations, {
    tableSha1 = Hashing.sha1hex(tableMember),
    memberSha1s = {
      { memberId = 1, sha1 = Hashing.sha1hex(member1) },
      { memberId = 2, sha1 = Hashing.sha1hex(member2) },
    },
  })
  Assert.equal(deps.terrainTextureSrt, false)
end

function T.error_contexts_name_the_record_schedule_and_source_member()
  local err = throwsCode("TERRAIN_ANIM_TEXTURE_INDEX_OUT_OF_RANGE", function()
    return compileScene({
      mapPack = basePack(),
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 18 }, { 3, 18 } } } }),
        [1] = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) }),
      },
    })
  end)
  Assert.equal(err.context.record, "flower01")
  Assert.equal(err.context.recordIndex, 0)
  Assert.equal(err.context.scheduleIndex, 1)
  Assert.equal(err.context.textureIndex, 3)
  Assert.equal(err.context.dictionarySize, 3)
  Assert.equal(err.context.source.alias, "field_texture_animations")
  Assert.equal(err.context.source.memberId, 1)
  Assert.equal(err.context.source.mapId, MAP_ID)
end

function T.error_contexts_name_material_texture_and_source_member()
  local err = throwsCode("TERRAIN_ANIM_TEXTURE_INCOMPATIBLE", function()
    return compileScene({
      mapPack = basePack(),
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 18 } } } }),
        [1] = Tex0Fixture.btx0({
          textures = { { name = "alt1", width = 16, height = 8 } },
          palettes = {},
        }),
      },
    })
  end)
  Assert.equal(err.context.record, "flower01")
  Assert.equal(err.context.recordIndex, 0)
  Assert.equal(err.context.material, "m_flower01")
  Assert.equal(err.context.texture, "flower01")
  Assert.equal(err.context.source.alias, "field_texture_animations")
  Assert.equal(err.context.source.memberId, 1)
  Assert.equal(err.context.source.mapId, MAP_ID)
end

function T.a_replacement_member_is_read_once_across_matching_materials()
  -- The replacement member is a per-compilation cache: two materials matched
  -- by one compiler (central and neighbor) read it once, and a second compiler
  -- reads its own copy -- no module-global cache.
  local scene = buildScene(animationSceneOpts())
  local counts = {}
  local romFs = {
    openNarc = function(_, alias)
      local narc = scene.romFs:openNarc(alias)
      return {
        memberCount = function()
          return narc:memberCount()
        end,
        readMember = function(_, memberId)
          counts[alias] = counts[alias] or {}
          counts[alias][memberId] = (counts[alias][memberId] or 0) + 1
          return narc:readMember(memberId)
        end,
      }
    end,
  }
  local function compile(compiler, role)
    local meshes, textures = {}, {}
    return ModelAssetCompiler.compileModel(terrainModel(), scene.pack, meshes, textures, {
      mapId = MAP_ID,
      role = role,
      textureArchive = "map_textures",
      textureMemberId = PACK_ID,
      modelArchive = "land_data",
      modelMemberId = LAND_MEMBER_ID,
      modelName = "map0",
      terrainAnimations = compiler,
    })
  end

  local compiler = TerrainAnimationCompiler.new(romFs, { mapId = MAP_ID, dynamicTextureType = 0xFFFF })
  Assert.equal(compile(compiler, "map").materials[1].textureSwap.name, "flower01")
  Assert.equal(compile(compiler, "neighbor").materials[1].textureSwap.name, "flower01")
  -- Member 0 (the table) is read once at construction; member 1 once for both
  -- matches. No other member is touched.
  Assert.deepEqual(counts.field_texture_animations, { [0] = 1, [1] = 1 })

  local compiler2 = TerrainAnimationCompiler.new(romFs, { mapId = MAP_ID, dynamicTextureType = 0xFFFF })
  compile(compiler2, "map")
  Assert.equal(counts.field_texture_animations[0], 2)
  Assert.equal(counts.field_texture_animations[1], 2)
end

function T.frame_zero_divergence_fires_the_compiler_invariant()
  -- The first live schedule entry must decode byte-identically to the base
  -- material texture; a divergent replacement is a compile invariant failure,
  -- never a silently divergent frame 0.
  local err = Assert.throws(function()
    return compileScene({
      mapPack = basePack(),
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 18 } } } }),
        [1] = replacementMember({ texels(0x22) }),
      },
    })
  end)
  Assert.isTrue(tostring(err):find("flower01") ~= nil, "the invariant failure names the record")
end

function T.an_all_sentinel_record_leaves_the_material_static()
  -- A record whose schedule is entirely the sentinel has no live frames and
  -- cannot drive a swap; the material stays static and the replacement member
  -- (absent from the fixture, so any read trips its assert) is never read.
  local scene = assert(compileScene({
    mapPack = basePack(),
    fieldTextureAnimations = { [0] = FieldTexAnimFixture.member({ { name = "flower01" } }) },
  }))
  Assert.isNil(scene.compiled.materials[1].textureSwap)
  Assert.notNil(scene.compiled.materials[1].texture)
  Assert.deepEqual(scene.compiler:dependencies().fieldTextureAnimations.memberSha1s, {})
end

return { tests = T }
