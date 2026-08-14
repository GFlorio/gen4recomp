-- Pure normalization of the compiled scene and model descriptors into the
-- records the loaders (MapSceneLoader, NeighborRing) assemble with GPU
-- resources: the GPU side of loading lives in those loaders, never here.
-- Scene and model material lists share one shape, so the sampler-wrap
-- resolution and the id index live here once; the material-to-wrap map an
-- animated model's pattern variants sample with, the per-mesh model-space
-- center/AABB the pool entry caches, and the per-model bounds fold over those
-- per-mesh AABBs are pure folds over the descriptor records and decoded
-- vertices. The scene-form material records the compilers emit always carry
-- their sampler state and the required lists are always present, so
-- normalization is strict: a missing wrap or list is malformed generated
-- data and raises, never a default. No love, no pool, no acquisition. The
-- per-mesh bounds shape is {minX,maxX,minY,maxY,minZ,maxZ}, shared with the
-- runtime placement records; the model bounds fold allocates a fresh table
-- per model, never aliasing a pooled mesh entry's cached AABB.

local Errors = require("libs.errors.src.Errors")
local ErrorCodes = require("libs.assets.src.ErrorCodes")

local SceneDescriptor = {}

local WRAP_MODES = { clamp = true, ["repeat"] = true }

-- Resolve a material record's sampler wrap. The compiler emits the wrap pair
-- on every material, so a missing or unknown wrap is malformed generated
-- data and raises instead of degrading to clamp.
function SceneDescriptor.wrap(record)
  local wrap = record.wrap
  if type(wrap) ~= "table" or not WRAP_MODES[wrap.x] or not WRAP_MODES[wrap.y] then
    Errors.raise(
      ErrorCodes.SCENE_DESC_BAD_WRAP,
      "material " .. tostring(record.id) .. " requires a wrap { x, y } of clamp/repeat",
      { material = record.id }
    )
  end
  return wrap
end

-- Normalize a scene-form material list into id-indexed records carrying the
-- resolved sampler wrap; the image itself is GPU-side work. A missing list
-- is malformed scene data, never an empty map. Terrain materials also carry
-- their texture-matrix inputs (texWidth/texHeight/texMtxMode, the optional
-- static srt, and the optional textureSwap descriptor): those ride the
-- normalized record for the terrain animator, present only when the compiled
-- record carries them (Lua omits nil fields). Each normalized record is a
-- fresh table, so runtime fields (image, texMatrix) written onto it never
-- alias back into the scene descriptor; the srt and textureSwap tables are
-- referenced, not copied -- the runtime treats them as immutable.
---@param list table[]
---@return table<number, { id: number, name: string, texture: string?, wrap: { x: string, y: string }, texWidth?: number, texHeight?: number, texMtxMode?: number, srt?: table, textureSwap?: table }>
function SceneDescriptor.materials(list)
  if type(list) ~= "table" then
    Errors.raise(ErrorCodes.SCENE_DESC_BAD_MATERIALS, "a material list is required", {})
  end
  local byId = {}
  for _, record in ipairs(list) do
    local wrap = SceneDescriptor.wrap(record)
    local normalized = {
      id = record.id,
      name = record.name,
      texture = record.texture,
      wrap = wrap,
      texWidth = record.texWidth,
      texHeight = record.texHeight,
      texMtxMode = record.texMtxMode,
      srt = record.srt,
      textureSwap = record.textureSwap,
    }
    byId[record.id] = normalized
  end
  return byId
end

-- Map every material id to its sampler wrap, so an animated model's variant
-- resolution (base texture and pattern variants alike) looks the wrap up by
-- material, never by texture path: two materials can share one texture under
-- different wraps, and a path-keyed map would silently overwrite one sampler
-- with the other.
---@param list table[]
---@return table<number, { x: string, y: string }>
function SceneDescriptor.wrapByMaterial(list)
  if type(list) ~= "table" then
    Errors.raise(ErrorCodes.SCENE_DESC_BAD_MATERIALS, "a material list is required", {})
  end
  local byMaterial = {}
  for _, record in ipairs(list) do
    byMaterial[record.id] = SceneDescriptor.wrap(record)
  end
  return byMaterial
end

-- Model-space bounding-box center and AABB of decoded vertices; the pool
-- mesh entry caches this per content-addressed path. A mesh with no
-- vertices is malformed data and raises instead of folding the inf/nan seed
-- values into a nonsense box.
---@param verts table[]
---@return { center: number[], bounds: { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number } }
function SceneDescriptor.meshGeometry(verts)
  if #verts == 0 then
    Errors.raise(ErrorCodes.SCENE_DESC_EMPTY_MESH, "a mesh must have at least one vertex", {})
  end
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

-- Fold per-mesh model-space AABBs into one model AABB, seeded with the
-- FIRST mesh's bounds: a model whose geometry lies away from the origin
-- never acquires an artificial origin-containing bound. The zero box is
-- only the fold of an actually empty model (no meshes).
---@param meshBounds { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number }[]
---@return { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number }
function SceneDescriptor.bounds(meshBounds)
  local first = meshBounds[1]
  local aabb = first
      and {
        minX = first.minX,
        maxX = first.maxX,
        minY = first.minY,
        maxY = first.maxY,
        minZ = first.minZ,
        maxZ = first.maxZ,
      }
    or { minX = 0, maxX = 0, minY = 0, maxY = 0, minZ = 0, maxZ = 0 }
  for i = 2, #meshBounds do
    local entry = meshBounds[i]
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
