-- Unit tests for SceneDescriptor, the pure descriptor normalization of scene
-- loading: material wrap resolution and id indexing, the material-keyed
-- sampler-wrap map an animated model's pattern variants need, and the
-- per-mesh geometry math (model-space center + AABB) plus the per-model
-- bounds fold that the loaders (MapSceneLoader/NeighborRing) consume from
-- the pool mesh entry instead of rescanning vertices. The scene-form
-- material records the compilers emit always carry their sampler wrap, so
-- normalization is strict: a missing wrap or a missing material list is
-- malformed generated data, never a default.

local Assert = require("tests.support.Assert")
local ErrorCodes = require("libs.assets.src.ErrorCodes")
local SceneDescriptor = require("libs.engine.src.SceneDescriptor")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

local function material(id, texture, wrap)
  return {
    id = id,
    name = "mat" .. id,
    texture = texture,
    wrap = wrap,
  }
end

-- A material record without a wrap is malformed generated data: the
-- compiler emits the sampler state on every material, so a missing wrap
-- raises instead of defaulting to clamp.
function T.missing_wrap_raises()
  throwsCode("SCENE_DESC_BAD_WRAP", function()
    SceneDescriptor.wrap({ id = 0, name = "mat", texture = "tex" })
  end)
  throwsCode("SCENE_DESC_BAD_WRAP", function()
    SceneDescriptor.wrap({ id = 0, name = "mat", texture = "tex", wrap = { x = "mirror", y = "clamp" } })
  end)
  local record = material(0, "tex", { x = "repeat", y = "repeat" })
  Assert.equal(SceneDescriptor.wrap(record), record.wrap, "an explicit wrap is preserved by identity")
end

-- Normalized material records are id-indexed and carry the resolved wrap.
function T.materials_index_by_id_with_resolved_wraps()
  local byId = SceneDescriptor.materials({
    material(0, "a.png", { x = "repeat", y = "repeat" }),
    material(1, "b.png", { x = "clamp", y = "clamp" }),
  })
  Assert.equal(byId[0] ~= nil and byId[1] ~= nil, true, "both ids are indexed")
  Assert.deepEqual(byId[0], { id = 0, name = "mat0", texture = "a.png", wrap = { x = "repeat", y = "repeat" } })
  Assert.deepEqual(byId[1], { id = 1, name = "mat1", texture = "b.png", wrap = { x = "clamp", y = "clamp" } })
end

-- A missing material list is malformed scene data, not an empty map.
function T.materials_requires_a_list()
  throwsCode("SCENE_DESC_BAD_MATERIALS", function()
    ---@diagnostic disable: param-type-mismatch
    SceneDescriptor.materials(nil)
  end)
end

-- The sampler-wrap map is keyed by material id (base texture and pattern
-- variants of one material share its wrap): a texture path does not uniquely
-- imply a wrap -- two materials can share pixels under different wraps -- so
-- a path-keyed map would silently overwrite one sampler with the other.
function T.wrap_by_material_maps_each_material_to_its_wrap()
  local list = {
    {
      id = 0,
      name = "mat0",
      texture = "base.png",
      wrap = { x = "repeat", y = "clamp" },
      variants = {
        { name = "v1", texture = "v1.png" },
        { name = "v2", texture = "v2.png" },
      },
    },
    { id = 1, name = "mat1", wrap = { x = "repeat", y = "repeat" } },
  }
  local byMaterial = SceneDescriptor.wrapByMaterial(list)
  Assert.deepEqual(byMaterial[0], { x = "repeat", y = "clamp" })
  Assert.deepEqual(byMaterial[1], { x = "repeat", y = "repeat" })
  -- Two materials sharing one texture under different wraps both resolve:
  -- neither overwrites the other.
  local shared = {
    { id = 0, name = "a", texture = "same.png", wrap = { x = "clamp", y = "clamp" } },
    { id = 1, name = "b", texture = "same.png", wrap = { x = "repeat", y = "repeat" } },
  }
  local byMaterial2 = SceneDescriptor.wrapByMaterial(shared)
  Assert.deepEqual(byMaterial2[0], { x = "clamp", y = "clamp" })
  Assert.deepEqual(byMaterial2[1], { x = "repeat", y = "repeat" })
end

-- The per-mesh geometry math: bounding-box center and {minX..maxZ} AABB of
-- the decoded vertices (the values the pool entry caches per path).
function T.mesh_geometry_computes_center_and_aabb()
  local g = SceneDescriptor.meshGeometry({ { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 2 } })
  Assert.deepEqual(g.center, { 1, 0, 1 }, "the center is the bounding-box midpoint")
  Assert.deepEqual(g.bounds, { minX = 0, maxX = 2, minY = 0, maxY = 0, minZ = 0, maxZ = 2 })
  local g2 = SceneDescriptor.meshGeometry({ { -4, 2, 6 }, { 4, 8, -6 } })
  Assert.deepEqual(g2.center, { 0, 5, 0 })
  Assert.deepEqual(g2.bounds, { minX = -4, maxX = 4, minY = 2, maxY = 8, minZ = -6, maxZ = 6 })
end

-- The model bounds fold unions per-mesh AABBs into one fresh table (never
-- aliasing an entry's cached table) and degrades to the zero AABB for a
-- model with no meshes.
function T.bounds_folds_per_mesh_aabbs_into_one_model_box()
  local a = { minX = 0, maxX = 2, minY = 0, maxY = 0, minZ = 0, maxZ = 2 }
  local b = { minX = 4, maxX = 5, minY = -1, maxY = 3, minZ = 2, maxZ = 9 }
  local folded = SceneDescriptor.bounds({ a, b })
  Assert.deepEqual(folded, { minX = 0, maxX = 5, minY = -1, maxY = 3, minZ = 0, maxZ = 9 })
  Assert.isFalse(folded == a, "the fold allocates a fresh table")
  Assert.isFalse(folded == b)
  Assert.deepEqual(SceneDescriptor.bounds({}), { minX = 0, maxX = 0, minY = 0, maxY = 0, minZ = 0, maxZ = 0 })
end

-- The aggregate AABB seeds from the FIRST mesh's bounds: a model whose
-- geometry lies entirely away from the origin must not acquire an
-- artificial origin-containing bound.
function T.bounds_seed_from_the_first_mesh_not_the_origin()
  local a = { minX = 10, maxX = 12, minY = 10, maxY = 14, minZ = 10, maxZ = 15 }
  local b = { minX = 18, maxX = 20, minY = 16, maxY = 20, minZ = 17, maxZ = 20 }
  local folded = SceneDescriptor.bounds({ a, b })
  Assert.deepEqual(folded, { minX = 10, maxX = 20, minY = 10, maxY = 20, minZ = 10, maxZ = 20 })
end

-- A mesh with no vertices is malformed data: the geometry math must fail
-- loudly, never fold the inf/nan seed values into a nonsense box.
function T.mesh_geometry_with_no_vertices_raises()
  throwsCode(ErrorCodes.SCENE_DESC_EMPTY_MESH, function()
    return SceneDescriptor.meshGeometry({})
  end)
end

return {
  tests = T,
}
