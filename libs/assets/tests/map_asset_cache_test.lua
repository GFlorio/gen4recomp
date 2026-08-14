-- MapAssetCache: path shapes, and readiness gated on an exact marker plus
-- present artifacts.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local CollisionFixture = require("tests.support.CollisionFixture")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local T = {}

local function cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

local function writeReadyMap(c, marker)
  local dir = MapAssetCache.mapDir(61)
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, terrain = { file = %q }, mapBatches = {}, materials = {}, buildingInstances = {}, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA,
      MapAssetCache.terrainPath(61)
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(MapAssetCache.terrainPath(61), "return { schema = 'g4-terrain-surfaces-v1' }\n")
  c:write(MapAssetCache.collisionPath(61), CollisionFixture.asset(32, 32))
  c:write(dir .. "/complete", marker)
end

function T.map_dir_is_zero_padded()
  Assert.equal(MapAssetCache.mapDir(61), "data/generated/maps/0061")
  Assert.equal(MapAssetCache.mapDir(60), "data/generated/maps/0060")
end

function T.model_path_is_filesystem_safe()
  Assert.equal(MapAssetCache.modelPath("indoor:22:abcdef"), "data/generated/models/indoor_22_abcdef.lua")
end

function T.not_ready_without_files()
  Assert.isTrue(not MapAssetCache.isReady(cache(), 61, MapAssetCache.marker("x", 61, "y")), "no files")
end

function T.ready_only_with_exact_marker_and_files()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  writeReadyMap(c, marker)
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "ready")
  Assert.isTrue(not MapAssetCache.isReady(c, 61, "different-marker"), "stale marker not ready")
end

function T.not_ready_when_referenced_asset_missing()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, mapBatches = { { geometry = 'assets/generated/maps/geometry/abc.g4mesh' } }, materials = {}, buildingInstances = {}, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(dir .. "/collision.g4collision", CollisionFixture.asset(32, 32))
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "missing mesh -> not ready")
end

function T.not_ready_with_malformed_collision_asset()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  writeReadyMap(c, marker)
  c:write(MapAssetCache.collisionPath(61), string.rep("\0", 100))
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "wrong collision bytes -> not ready")
end

function T.not_ready_when_model_descriptor_references_missing_asset()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  local modelKey = "indoor:1:abc"
  local modelPath = MapAssetCache.modelPath(modelKey)
  local meshPath = "assets/generated/maps/geometry/missing.g4mesh"
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, mapBatches = {}, materials = {}, buildingInstances = { { modelKey = %q } }, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA,
      modelKey
    )
  )
  c:write(dir .. "/collision.g4collision", CollisionFixture.asset(32, 32))
  c:write(
    modelPath,
    string.format(
      "return { schema = 'g4-model-v2', key = %q, memberId = 1, kind = 'static', batches = { { geometry = %q } }, materials = {} }\n",
      modelKey,
      meshPath
    )
  )
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "missing model-internal geometry -> not ready")
end

function T.not_ready_when_model_descriptor_has_the_wrong_kind()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  local modelKey = "indoor:1:abc"
  local modelPath = MapAssetCache.modelPath(modelKey)
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, mapBatches = {}, materials = {}, buildingInstances = { { modelKey = %q } }, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA,
      modelKey
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(dir .. "/collision.g4collision", CollisionFixture.asset(32, 32))
  -- A descriptor without the explicit schema/kind must not read as ready.
  c:write(modelPath, "return { batches = {}, materials = {} }\n")
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "schema-less descriptor -> not ready")
end

function T.not_ready_when_a_variant_texture_is_missing()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  local modelKey = "indoor:1:abc"
  local modelPath = MapAssetCache.modelPath(modelKey)
  local baseTexture = "assets/generated/maps/textures/base.png"
  local variantTexture = "assets/generated/maps/textures/variant.png"
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, terrain = { file = %q }, mapBatches = {}, materials = {}, buildingInstances = { { modelKey = %q } }, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA,
      MapAssetCache.terrainPath(61),
      modelKey
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(dir .. "/collision.g4collision", CollisionFixture.asset(32, 32))
  c:write(MapAssetCache.terrainPath(61), "return { schema = 'g4-terrain-surfaces-v1' }\n")
  c:write(
    modelPath,
    string.format(
      "return { schema = 'g4-model-v2', key = %q, memberId = 1, kind = 'static', batches = {}, materials = { { id = 0, name = 'wall', texture = %q, textureFormat = 3, wrap = { x = 'clamp', y = 'clamp' }, flip = { x = false, y = false }, diffuse = { r = 255, g = 255, b = 255, a = 255 }, variants = { { name = 'sign.a', texture = %q } } } } }\n",
      modelKey,
      baseTexture,
      variantTexture
    )
  )
  c:write(baseTexture, "png")
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "missing variant texture -> not ready")
  c:write(variantTexture, "png")
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "with the variant present the map is ready")
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

function T.referenced_paths_includes_neighbor_batches_and_materials()
  local neighborGeometry = "assets/generated/maps/geometry/abc.g4mesh"
  local neighborTexture = "assets/generated/maps/textures/def.png"
  local neighborCollision = "data/generated/maps/0060/neighbors/3/collision.g4collision"
  local neighborTerrain = "data/generated/maps/0060/neighbors/3/terrain.lua"
  local scene = {
    schema = "g4-map-scene-v5",
    mapId = 61,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {
      {
        offsetTilesX = 1,
        offsetTilesZ = 0,
        batches = { { geometry = neighborGeometry, material = 0 } },
        materials = { { id = 0, texture = neighborTexture, texWidth = 16, texHeight = 16, texMtxMode = 0 } },
        collision = { file = neighborCollision },
        terrain = { file = neighborTerrain },
      },
    },
    terrainAnimations = { textureSrt = false },
  }
  local paths = MapAssetCache.referencedPaths(scene, nil)
  Assert.isTrue(contains(paths, neighborGeometry), "missing neighbor geometry path")
  Assert.isTrue(contains(paths, neighborTexture), "missing neighbor texture path")
  Assert.isTrue(contains(paths, neighborCollision), "missing neighbor collision path")
  Assert.isTrue(contains(paths, neighborTerrain), "missing neighbor terrain path")
end

-- ---- v5 terrain-animation contract ----

local BASE_TEX = "assets/generated/maps/textures/base.png"
local ALT1_TEX = "assets/generated/maps/textures/alt1.png"
local ALT2_TEX = "assets/generated/maps/textures/alt2.png"

-- A minimal current-schema scene: no batches, no models, no neighbors, and
-- the required terrainAnimations table with the explicit false clip.
local function baseScene()
  return {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = 61,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {},
    terrainAnimations = { textureSrt = false },
  }
end

-- Build a scene and apply one mutation, so every malformed-shape case shares
-- the exact same otherwise-valid base.
local function patchedScene(mutator)
  local s = baseScene()
  mutator(s)
  return s
end

-- A textured terrain material with the textureSwap record and the v5 terrain
-- fields (texWidth/texHeight/texMtxMode).
local function swapMaterial(texture, textures, timeline)
  return {
    id = 0,
    name = "flower01",
    texture = texture,
    textureFormat = 3,
    wrap = { x = "repeat", y = "repeat" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
    textureSwap = { name = "flower01", textures = textures, timeline = timeline },
  }
end

local FLOWER_TIMELINE = {
  { textureIndex = 0, durationTicks = 18 },
  { textureIndex = 1, durationTicks = 18 },
  { textureIndex = 0, durationTicks = 18 },
  { textureIndex = 2, durationTicks = 18 },
}

local function constant(value)
  return { source = "constant", value = value }
end

-- The data-only clip shape the terrain compiler emits (NsbtaClipCompiler
-- payload plus the clip envelope, without physical source fields).
local function srtClip()
  return {
    id = "area00_ani",
    name = "area00_ani",
    category = "material",
    kind = "texsrt",
    frameCount = 360,
    tracks = {
      { target = "pond_on", targetIndex = 0 },
      { target = "sea_un", targetIndex = 1 },
    },
    semanticNames = {},
    compiled = {
      targets = {
        {
          index = 0,
          name = "pond_on",
          channels = {
            transS = constant(0),
            transT = constant(0),
            rot = constant(0x10000000),
            scaleS = constant(0x1000),
            scaleT = constant(0x1000),
          },
        },
        {
          index = 1,
          name = "sea_un",
          channels = {
            transS = {
              source = "curve",
              rate = 1,
              limit = 8,
              storage = "fx16",
              keys = { 0, 256, 512, 768, 1024, 1280, 1536, 1792 },
            },
            transT = constant(0),
            rot = constant(0x10000000),
            scaleS = constant(0x1000),
            scaleT = constant(0x1000),
          },
        },
      },
    },
  }
end

local function raisesSceneInvalid(scene)
  local err = Assert.throws(function()
    MapAssetCache.referencedPaths(scene, nil)
  end)
  Assert.equal(err.code, "MAP_CACHE_SCENE_INVALID")
end

-- Write a full ready map for `scene`, with exactly the given extra image
-- paths present (written explicitly, never derived from the traversal under
-- test).
local function writeSceneArtifacts(c, scene, marker, imagePaths)
  local dir = MapAssetCache.mapDir(scene.mapId)
  c:writeLua(dir .. "/scene.lua", scene)
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(MapAssetCache.terrainPath(scene.mapId), "return { schema = 'g4-terrain-surfaces-v1' }\n")
  c:write(MapAssetCache.collisionPath(scene.mapId), CollisionFixture.asset(32, 32))
  for _, path in ipairs(imagePaths or {}) do
    c:write(path, "png")
  end
  c:write(dir .. "/complete", marker)
end

-- Mutator helpers for the malformed material/clip/swap batteries below.
local function materialPatch(mutate)
  return patchedScene(function(s)
    local m = {
      id = 0,
      name = "m0",
      texture = BASE_TEX,
      texWidth = 16,
      texHeight = 16,
      texMtxMode = 0,
    }
    mutate(m)
    s.materials = { m }
  end)
end

local function clipPatch(mutate)
  return patchedScene(function(s)
    local clip = srtClip()
    mutate(clip)
    s.terrainAnimations = { textureSrt = clip }
  end)
end

local function swapPatch(mutate)
  return patchedScene(function(s)
    local m = swapMaterial(BASE_TEX, { BASE_TEX, ALT1_TEX }, {
      { textureIndex = 0, durationTicks = 18 },
      { textureIndex = 1, durationTicks = 18 },
    })
    mutate(m)
    s.materials = { m }
  end)
end

function T.current_scene_requires_terrain_animations()
  raisesSceneInvalid(patchedScene(function(s)
    s.terrainAnimations = nil
  end))
end

function T.malformed_terrain_animations_raise_scene_invalid()
  local cases = {
    function(s)
      s.terrainAnimations = "animations"
    end,
    function(s)
      s.terrainAnimations = {}
    end,
    function(s)
      s.terrainAnimations = { textureSrt = "no" }
    end,
    function(s)
      s.terrainAnimations = { textureSrt = 5 }
    end,
  }
  for _, mutate in ipairs(cases) do
    raisesSceneInvalid(patchedScene(mutate))
  end
end

function T.a_valid_false_clip_is_accepted()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local s = baseScene()
  s.terrain = { file = MapAssetCache.terrainPath(61) }
  writeSceneArtifacts(c, s, marker)
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "textureSrt = false is a valid scene")
end

function T.valid_clip_and_texture_swap_shapes_are_accepted()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local s = baseScene()
  s.terrain = { file = MapAssetCache.terrainPath(61) }
  s.terrainAnimations = { textureSrt = srtClip() }
  s.materials = {
    swapMaterial(BASE_TEX, { BASE_TEX, ALT1_TEX }, {
      { textureIndex = 0, durationTicks = 18 },
      { textureIndex = 1, durationTicks = 18 },
    }),
  }
  s.neighbors = {
    {
      offsetTilesX = 1,
      offsetTilesZ = 0,
      batches = {},
      materials = {
        swapMaterial(ALT1_TEX, { ALT1_TEX, BASE_TEX }, {
          { textureIndex = 0, durationTicks = 18 },
          { textureIndex = 1, durationTicks = 18 },
        }),
      },
    },
  }
  writeSceneArtifacts(c, s, marker, { BASE_TEX, ALT1_TEX })
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "a valid clip and textureSwap records are accepted")
end

function T.referenced_paths_includes_every_alternate_texture()
  local s = baseScene()
  s.materials = {
    swapMaterial(BASE_TEX, { BASE_TEX, ALT1_TEX, ALT2_TEX }, FLOWER_TIMELINE),
  }
  s.neighbors = {
    {
      offsetTilesX = 1,
      offsetTilesZ = 0,
      batches = {},
      materials = {
        swapMaterial(ALT1_TEX, { ALT1_TEX, ALT2_TEX }, {
          { textureIndex = 0, durationTicks = 18 },
          { textureIndex = 1, durationTicks = 18 },
        }),
      },
    },
  }
  local paths = MapAssetCache.referencedPaths(s, nil)
  for _, path in ipairs({ BASE_TEX, ALT1_TEX, ALT2_TEX }) do
    Assert.isTrue(contains(paths, path), "missing alternate texture path " .. path)
  end
end

function T.a_missing_alternate_image_makes_is_ready_false()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local s = baseScene()
  s.terrain = { file = MapAssetCache.terrainPath(61) }
  s.materials = {
    swapMaterial(BASE_TEX, { BASE_TEX, ALT1_TEX }, {
      { textureIndex = 0, durationTicks = 18 },
      { textureIndex = 1, durationTicks = 18 },
    }),
  }
  writeSceneArtifacts(c, s, marker, { BASE_TEX })
  Assert.isFalse(MapAssetCache.isReady(c, 61, marker), "the missing alternate image keeps the map not ready")
  c:write(ALT1_TEX, "png")
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "with the alternate present the map is ready")
end

function T.malformed_clip_shapes_raise_scene_invalid()
  local cases = {
    function(c)
      c.id = ""
    end,
    function(c)
      c.name = 5
    end,
    function(c)
      c.category = "joint"
    end,
    function(c)
      c.kind = "trs"
    end,
    function(c)
      c.frameCount = 0
    end,
    function(c)
      c.frameCount = 2.5
    end,
    function(c)
      c.tracks = "tracks"
    end,
    function(c)
      c.semanticNames = "names"
    end,
    function(c)
      c.compiled = {}
    end,
    function(c)
      c.compiled.targets = {}
    end,
    function(c)
      c.tracks = { { target = "", targetIndex = 0 } }
    end,
    function(c)
      c.tracks = { { target = "pond_on", targetIndex = -1 } }
    end,
    function(c)
      c.tracks = { { target = "pond_on", targetIndex = 0.5 } }
    end,
    function(c)
      c.compiled.targets[1].channels.scaleT = nil
    end,
    function(c)
      c.compiled.targets[1].channels.scaleS = { source = "linear", value = 0 }
    end,
    function(c)
      c.compiled.targets[1].channels.transS = constant(1.5)
    end,
    function(c)
      c.compiled.targets[1].channels.transT = { source = "curve", rate = 1, limit = 0, storage = "fx16", keys = { 0 } }
    end,
    function(c)
      c.compiled.targets[1].channels.transT =
        { source = "curve", rate = 1, limit = 4, storage = "fx8", keys = { 0, 1 } }
    end,
    function(c)
      c.compiled.targets[1].channels.transT = { source = "curve", rate = 1, limit = 4, storage = "fx16", keys = {} }
    end,
    function(c)
      c.compiled.targets[1].channels.transT =
        { source = "curve", rate = 1, limit = 4, storage = "fx16", keys = { 0.5 } }
    end,
    function(c)
      c.compiled.targets[1].channels.transT =
        { source = "curve", rate = 0, limit = 4, storage = "fx16", keys = { 0, 1 } }
    end,
  }
  for _, mutate in ipairs(cases) do
    raisesSceneInvalid(clipPatch(mutate))
  end
end

function T.malformed_texture_swap_shapes_raise_scene_invalid()
  local cases = {
    function(m)
      m.textureSwap.name = ""
    end,
    function(m)
      m.textureSwap.textures = {}
    end,
    function(m)
      m.textureSwap.textures = { named = 1 }
    end,
    function(m)
      m.textureSwap.timeline = {}
    end,
    function(m)
      m.textureSwap.timeline = { { textureIndex = 2, durationTicks = 18 } }
    end,
    function(m)
      m.textureSwap.timeline = { { textureIndex = -1, durationTicks = 18 } }
    end,
    function(m)
      m.textureSwap.timeline = { { textureIndex = 0, durationTicks = 0 } }
    end,
    function(m)
      m.textureSwap.timeline = { { textureIndex = 0, durationTicks = 2.5 } }
    end,
    function(m)
      m.textureSwap.timeline = { 5 }
    end,
    function(m)
      m.textureSwap.timeline = { { textureIndex = 1, durationTicks = 18 } }
    end,
    function(m)
      m.texture = nil
    end,
  }
  for _, mutate in ipairs(cases) do
    raisesSceneInvalid(swapPatch(mutate))
  end
end

function T.malformed_material_terrain_fields_raise_scene_invalid()
  local cases = {
    function(m)
      m.texWidth = 0
    end,
    function(m)
      m.texWidth = -4
    end,
    function(m)
      m.texWidth = 2.5
    end,
    function(m)
      m.texHeight = "16"
    end,
    function(m)
      m.texMtxMode = 0.5
    end,
    function(m)
      m.texMtxMode = "0"
    end,
    function(m)
      m.srt =
        { scaleS = 4096.5, scaleT = 4096, transS = 0, transT = 0, scaleOne = true, transOne = true, rotOne = true }
    end,
    function(m)
      m.srt = {
        scaleS = 4096,
        scaleT = 4096,
        transS = 0,
        transT = 0,
        rot = 5,
        scaleOne = true,
        transOne = true,
        rotOne = true,
      }
    end,
  }
  for _, mutate in ipairs(cases) do
    raisesSceneInvalid(materialPatch(mutate))
  end
end

-- ---- additional strictness rules ----

function T.duplicate_material_ids_in_one_list_raise_scene_invalid()
  local function withMaterials(materials)
    return patchedScene(function(s)
      s.materials = materials
    end)
  end
  raisesSceneInvalid(withMaterials({
    { id = 0, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
    { id = 0, name = "b", texture = ALT1_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
  }))
  raisesSceneInvalid(withMaterials({
    { id = 3, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
    { id = 3, name = "b", texture = ALT1_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
  }))
end

function T.duplicate_material_ids_in_one_neighbor_list_raise_scene_invalid()
  raisesSceneInvalid(patchedScene(function(s)
    s.neighbors = {
      {
        offsetTilesX = 1,
        offsetTilesZ = 0,
        batches = {},
        materials = {
          { id = 0, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
          { id = 0, name = "b", texture = ALT1_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
        },
      },
    }
  end))
end

function T.the_same_material_id_in_different_lists_is_valid()
  local s = baseScene()
  s.materials = {
    { id = 0, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
  }
  s.neighbors = {
    {
      offsetTilesX = 1,
      offsetTilesZ = 0,
      batches = {},
      materials = {
        { id = 0, name = "b", texture = ALT1_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
      },
    },
  }
  Assert.isTrue(type(MapAssetCache.referencedPaths(s, nil)) == "table", "ids are scoped per list")
end

function T.unknown_texture_matrix_modes_raise_scene_invalid()
  local cases = {
    function(m)
      m.texMtxMode = 4
    end,
    function(m)
      m.texMtxMode = -1
    end,
  }
  for _, mutate in ipairs(cases) do
    raisesSceneInvalid(materialPatch(mutate))
  end
end

function T.non_finite_numbers_raise_scene_invalid()
  local nan = 0 / 0
  local inf = math.huge
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = { scaleS = nan, scaleT = 4096, transS = 0, transT = 0, scaleOne = true, transOne = true, rotOne = true }
  end))
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = {
      scaleS = 4096,
      scaleT = 4096,
      transS = 0,
      transT = 0,
      rot = { sin = inf, cos = 0 },
      scaleOne = true,
      transOne = true,
      rotOne = true,
    }
  end))
  raisesSceneInvalid(clipPatch(function(c)
    c.compiled.targets[1].channels.transS = constant(nan)
  end))
  raisesSceneInvalid(clipPatch(function(c)
    c.compiled.targets[1].channels.transS =
      { source = "curve", rate = 1, limit = 4, storage = "fx16", keys = { inf, 1 } }
  end))
end

function T.incomplete_srt_tables_raise_scene_invalid()
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = {}
  end))
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = { scaleS = 4096, scaleT = 4096, transS = 0, transT = 0, scaleOne = true, transOne = true }
  end))
end

function T.fractional_rotation_components_raise_scene_invalid()
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = {
      scaleS = 4096,
      scaleT = 4096,
      transS = 0,
      transT = 0,
      rot = { sin = 0.5, cos = 0 },
      scaleOne = true,
      transOne = true,
      rotOne = true,
    }
  end))
end

function T.non_string_swap_textures_raise_scene_invalid()
  raisesSceneInvalid(swapPatch(function(m)
    m.textureSwap.textures = { BASE_TEX, 5 }
  end))
  raisesSceneInvalid(swapPatch(function(m)
    m.textureSwap.textures = { BASE_TEX, "" }
  end))
end

function T.untextured_materials_need_no_terrain_fields()
  local s = baseScene()
  s.materials = { { id = 0, name = "untextured" } }
  Assert.isTrue(
    type(MapAssetCache.referencedPaths(s, nil)) == "table",
    "an untextured material is valid without terrain fields"
  )
end

function T.clip_track_index_beyond_compiled_targets_raises_scene_invalid()
  raisesSceneInvalid(clipPatch(function(c)
    c.tracks = { { target = "pond_on", targetIndex = 5 } }
  end))
end

function T.clip_target_without_channels_raises_scene_invalid()
  raisesSceneInvalid(clipPatch(function(c)
    c.compiled.targets[1] = { index = 0, name = "pond_on" }
  end))
end

function T.world_path_is_stable()
  Assert.equal(type(MapAssetCache.worldPath()), "string")
  Assert.isTrue(MapAssetCache.worldPath():match("world%.lua$") ~= nil)
end

return { tests = T }
