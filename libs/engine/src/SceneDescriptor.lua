-- Pure normalization of the compiled scene and model descriptors into the
-- records the loaders (MapSceneLoader, NeighborRing) assemble with GPU
-- resources: the GPU side of loading lives in those loaders, never here.
-- Scene and model material lists share one shape, so the sampler-wrap
-- resolution and the id index live here once; the texture-to-wrap map an
-- animated model's pattern variants sample with, the per-mesh model-space
-- center/AABB the pool entry caches, and the per-model bounds fold over those
-- per-mesh AABBs are pure folds over the descriptor records and decoded
-- vertices. No love, no pool, no acquisition. The per-mesh bounds shape is
-- {minX,maxX,minY,maxY,minZ,maxZ}, shared with the runtime placement
-- records; the model bounds fold allocates a fresh table per model, never
-- aliasing a pooled mesh entry's cached AABB.

local SceneDescriptor = {}

-- Resolve a material record's sampler wrap; a missing wrap means clamp/clamp
-- (the pre-schema default the compiler has emitted explicitly since
-- map-compiler-v17).
function SceneDescriptor.wrap(record)
  return record.wrap or { x = "clamp", y = "clamp" }
end

-- Normalize a scene-form material list into id-indexed records carrying the
-- resolved sampler wrap; the image itself is GPU-side work.
---@param list table[]?
---@return table<number, { id: number, name: string, texture: string?, wrap: { x: string, y: string } }>
function SceneDescriptor.materials(list)
  local byId = {}
  for _, record in ipairs(list or {}) do
    local wrap = SceneDescriptor.wrap(record)
    byId[record.id] = { id = record.id, name = record.name, texture = record.texture, wrap = wrap }
  end
  return byId
end

-- Map every texture key a model's material list can sample -- base textures
-- and pattern variants alike -- to the owning material's wrap, so a variant
-- never resolves with a different sampler than its material.
---@param list table[]?
---@return table<string, { x: string, y: string }>
function SceneDescriptor.wrapByTexture(list)
  local byTexture = {}
  for _, record in ipairs(list or {}) do
    local wrap = SceneDescriptor.wrap(record)
    if record.texture then
      byTexture[record.texture] = wrap
    end
    for _, variant in ipairs(record.variants or {}) do
      if variant.texture then
        byTexture[variant.texture] = wrap
      end
    end
  end
  return byTexture
end

-- Model-space bounding-box center and AABB of decoded vertices; the pool
-- mesh entry caches this per content-addressed path.
---@param verts table[]
---@return { center: number[], bounds: { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number } }
function SceneDescriptor.meshGeometry(verts)
  local minx, miny, minz = math.huge, math.huge, math.huge
  local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
  for _, v in ipairs(verts) do
    minx = math.min(minx, v[1])
    maxx = math.max(maxx, v[1])
    miny = math.min(miny, v[2])
    maxy = math.max(maxy, v[2])
    minz = math.min(minz, v[3])
    maxz = math.max(maxz, v[3])
  end
  return {
    center = { (minx + maxx) / 2, (miny + maxy) / 2, (minz + maxz) / 2 },
    bounds = { minX = minx, maxX = maxx, minY = miny, maxY = maxy, minZ = minz, maxZ = maxz },
  }
end

-- Fold per-mesh model-space AABBs into one model AABB, seeded with the zero
-- box: an empty model folds to it, and every non-empty model's box contains
-- the origin (the pre-refactor vertex-union semantics did not).
---@param meshBounds { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number }[]
---@return { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number }
function SceneDescriptor.bounds(meshBounds)
  local aabb = { minX = 0, maxX = 0, minY = 0, maxY = 0, minZ = 0, maxZ = 0 }
  for _, entry in ipairs(meshBounds) do
    aabb.minX = math.min(aabb.minX, entry.minX)
    aabb.maxX = math.max(aabb.maxX, entry.maxX)
    aabb.minY = math.min(aabb.minY, entry.minY)
    aabb.maxY = math.max(aabb.maxY, entry.maxY)
    aabb.minZ = math.min(aabb.minZ, entry.minZ)
    aabb.maxZ = math.max(aabb.maxZ, entry.maxZ)
  end
  return aabb
end

return SceneDescriptor
