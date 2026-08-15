-- Pure folds over the compiled scene and model descriptors the loaders
-- (MapSceneLoader, NeighborRing) assemble with GPU resources: the GPU side
-- of loading lives in those loaders, never here. Scene and model material
-- lists share one shape, so the sampler-wrap resolution and the id index
-- live here once; the material-to-wrap map an animated model's pattern
-- variants sample with, the per-mesh model-space center/AABB the pool entry
-- caches, and the per-model bounds fold over those per-mesh AABBs are pure
-- folds over the descriptor records and decoded vertices. The scene-form
-- material records the compilers emit always carry their sampler state and
-- the required lists are always present, so the folds are strict: a missing
-- wrap or list is malformed generated data and raises, never a default. The
-- indexed records are the original descriptor records -- SceneDescriptor
-- records are read-only, and the loaders construct separate mutable runtime
-- tables. No love, no pool, no acquisition. The per-mesh bounds shape is
-- {minX,maxX,minY,maxY,minZ,maxZ}, shared with the runtime placement
-- records; the model bounds fold allocates a fresh table per model, never
-- aliasing a pooled mesh entry's cached AABB.

local Errors = require("libs.errors.src.Errors")
local ErrorCodes = require("libs.assets.src.ErrorCodes")

local SceneDescriptor = {}

local WRAP_MODES = { clamp = true, ["repeat"] = true }

-- Fold a resolved axis wrap with the NSBTX flip bit for that axis: DS mirrored
-- repeat only has a visible effect under repeat -- flip on a clamped axis is
-- inert, since mirroring never applies without wraparound -- so clamp always
-- wins.
local function foldAxis(mode, flip)
  if mode == "repeat" and flip then
    return "mirroredrepeat"
  end
  return mode
end

-- Resolve a material record's sampler wrap. The compiler emits the wrap pair
-- on every material, so a missing or unknown wrap is malformed generated
-- data and raises instead of degrading to clamp. `record.flip` (present when
-- the material's NSBTX TEXIMAGE_PARAM sets a flip bit) folds a repeated axis
-- into the exact DS mirrored-repeat sampler mode; its absence means no axis
-- ever flips.
function SceneDescriptor.wrap(record)
  local wrap = record.wrap
  if type(wrap) ~= "table" or not WRAP_MODES[wrap.x] or not WRAP_MODES[wrap.y] then
    Errors.raise(
      ErrorCodes.SCENE_DESC_BAD_WRAP,
      "material " .. tostring(record.id) .. " requires a wrap { x, y } of clamp/repeat",
      { material = record.id }
    )
  end
  local flip = record.flip
  if not flip or (not flip.x and not flip.y) then
    return wrap
  end
  return { x = foldAxis(wrap.x, flip.x), y = foldAxis(wrap.y, flip.y) }
end

-- Index a scene-form material list by id, validating each record's sampler
-- wrap; a missing list is malformed scene data, never an empty map. The
-- indexed records are the original descriptor records: SceneDescriptor
-- records are read-only, and the loaders construct separate mutable runtime
-- tables (image, texMatrix) before any mutation. The srt and textureSwap
-- tables are referenced, not copied -- the runtime treats them as immutable.
---@param list table[]
---@return table<number, table>
function SceneDescriptor.materials(list)
  if type(list) ~= "table" then
    Errors.raise(ErrorCodes.SCENE_DESC_BAD_MATERIALS, "a material list is required", {})
  end
  local byId = {}
  for _, record in ipairs(list) do
    SceneDescriptor.wrap(record)
    byId[record.id] = record
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
