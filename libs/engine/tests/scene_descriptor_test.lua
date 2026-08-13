-- Unit tests for SceneDescriptor, the pure descriptor normalization of scene
-- loading: material wrap resolution and id indexing, the texture-to-wrap map
-- an animated model's pattern variants need, and the per-mesh geometry math
-- (model-space center + AABB) plus the per-model bounds fold that the
-- loaders (MapSceneLoader/NeighborRing) consume from the pool mesh entry
-- instead of rescanning vertices.

local Assert = require("tests.support.Assert")
local ErrorCodes = require("libs.assets.src.ErrorCodes")
local SceneDescriptor = require("libs.engine.src.SceneDescriptor")

local T = {}

local function material(id, texture, wrap)
  return {
    id = id,
    name = "mat" .. id,
    texture = texture,
    wrap = wrap,
  }
end

-- A record without a wrap defaults to clamp/clamp.
function T.missing_wrap_defaults_to_clamp()
  local wrap = SceneDescriptor.wrap({ id = 0, name = "mat", texture = "tex" })
  Assert.deepEqual(wrap, { x = "clamp", y = "clamp" })
  local record = material(0, "tex", { x = "repeat", y = "repeat" })
  Assert.equal(SceneDescriptor.wrap(record), record.wrap, "an explicit wrap is preserved by identity")
end

-- Normalized material records are id-indexed and carry the resolved wrap.
function T.materials_index_by_id_with_resolved_wraps()
  local byId = SceneDescriptor.materials({
    material(0, "a.png", { x = "repeat", y = "repeat" }),
    material(1, "b.png", nil),
  })
  Assert.equal(byId[0] ~= nil and byId[1] ~= nil, true, "both ids are indexed")
  Assert.deepEqual(byId[0], { id = 0, name = "mat0", texture = "a.png", wrap = { x = "repeat", y = "repeat" } })
  Assert.deepEqual(byId[1], { id = 1, name = "mat1", texture = "b.png", wrap = { x = "clamp", y = "clamp" } })
  Assert.deepEqual(SceneDescriptor.materials(nil), {}, "a missing material list normalizes to an empty map")
end

-- Every texture key a material can sample -- base and pattern variants --
-- maps to the owning material's wrap, so a variant never resolves with a
-- different sampler than its material.
function T.wrap_by_texture_covers_base_and_variants()
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
    { id = 1, name = "mat1", wrap = nil },
  }
  local byTexture = SceneDescriptor.wrapByTexture(list)
  Assert.deepEqual(byTexture["base.png"], { x = "repeat", y = "clamp" })
  Assert.deepEqual(byTexture["v1.png"], { x = "repeat", y = "clamp" })
  Assert.deepEqual(byTexture["v2.png"], { x = "repeat", y = "clamp" })
  Assert.equal(byTexture["untextured"], nil, "a material without a texture maps nothing")
  Assert.deepEqual(SceneDescriptor.wrapByTexture(nil), {})
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

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
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
  metadata = { layer = "unit" },
  tests = T,
}
