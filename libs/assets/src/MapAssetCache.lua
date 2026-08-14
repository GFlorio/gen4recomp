-- Readiness for the derived map-asset cache. This cache has its own format
-- version, fully independent of the raw ROM dump: changing it may rebuild
-- derived maps but must never disturb the raw-dump completion marker,
-- romfs/, or the raw dump indexes. A map is ready only when its completion
-- marker matches exactly and every artifact it references is present and
-- loadable, so a partial or stale build never reads as complete. Paths are
-- cache-relative; all IO goes through a CacheFs (which confines every write
-- to the version subtree).

local MapAssetCache = {}

local Errors = require("libs.errors.src.Errors")
local AssetErrors = require("libs.assets.src.errors")
local Validate = require("libs.assets.src.Validate")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local CompiledNsbtaClip = require("libs.assets.src.CompiledNsbtaClip")
local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.ModelAsset")

MapAssetCache.FORMAT = Contract.map.cacheFormat
MapAssetCache.SCENE_SCHEMA = Contract.map.sceneSchema
MapAssetCache.TERRAIN_SCHEMA = Contract.map.terrainSchema

local DERIVED_DATA = "data/generated"
local DERIVED_ASSETS = "assets/generated"

function MapAssetCache.mapDir(mapId)
  return string.format("%s/maps/%04d", DERIVED_DATA, mapId)
end

function MapAssetCache.terrainPath(mapId)
  return MapAssetCache.mapDir(mapId) .. "/terrain.lua"
end

function MapAssetCache.collisionPath(mapId)
  return MapAssetCache.mapDir(mapId) .. "/collision.g4collision"
end

function MapAssetCache.neighborCollisionPath(mapId, landDataMemberId)
  return string.format("%s/neighbors/%d/collision.g4collision", MapAssetCache.mapDir(mapId), landDataMemberId)
end

function MapAssetCache.neighborTerrainPath(mapId, landDataMemberId)
  return string.format("%s/neighbors/%d/terrain.lua", MapAssetCache.mapDir(mapId), landDataMemberId)
end

-- Cache-relative path to the whole-ROM world manifest (map index the game boots
-- and switches on). Lives next to the per-map dirs, under the derived root.
function MapAssetCache.worldPath()
  return DERIVED_DATA .. "/world.lua"
end

function MapAssetCache.geometryPath(sha1)
  return string.format("%s/maps/geometry/%s.g4mesh", DERIVED_ASSETS, sha1)
end

function MapAssetCache.texturePath(sha1)
  return string.format("%s/maps/textures/%s.png", DERIVED_ASSETS, sha1)
end

function MapAssetCache.modelPath(modelKey)
  -- Model keys embed ':' (archive:member:hash); keep them filesystem-safe.
  return string.format("%s/models/%s.lua", DERIVED_DATA, (modelKey:gsub(":", "_")))
end

function MapAssetCache.marker(romSha1, mapId, depHash)
  return string.format("%s:%s:%d:%s", MapAssetCache.FORMAT, romSha1, mapId, depHash)
end

-- ---- terrain-animation subset validation ----
--
-- The current scene schema carries the strict generated terrain-animation
-- subset: the required terrainAnimations block (an explicit false clip or
-- the data-only texture-SRT clip shape the producer's NsbtaClipCompiler
-- emits), and the terrain material fields (texWidth/texHeight/texMtxMode,
-- the optional fixed-point srt, and the optional textureSwap record). The
-- compiled clip contract is the shared validator's; the checks here cover
-- only the scene material fields. Every check raises through the caller's
-- `invalid(reason)` so a malformed current-schema scene reports
-- MAP_CACHE_SCENE_INVALID.

local TERRAIN_SRT_FIELDS = { "transS", "transT", "scaleS", "scaleT" }
local TERRAIN_SRT_ONES = { "scaleOne", "transOne", "rotOne" }

-- A finite integer (rejects fractional, NaN, and infinite values).
---@param value any
---@return boolean
local function isFiniteInteger(value)
  return type(value) == "number" and value % 1 == 0
end

-- The optional fixed-point srt table (the MaterialEvaluator shape): the four
-- translation/scale fixed-point values, an optional { sin, cos } rotation
-- (omitted for identity rotation), and the three "one" flags.
local function checkTerrainSrt(srt, invalid)
  for _, field in ipairs(TERRAIN_SRT_FIELDS) do
    if not isFiniteInteger(srt[field]) then
      invalid("a material srt." .. field .. " must be a fixed-point integer")
    end
  end
  local rot = srt.rot
  if rot ~= nil and (type(rot) ~= "table" or not isFiniteInteger(rot.sin) or not isFiniteInteger(rot.cos)) then
    invalid("a material srt.rot must be { sin, cos } fixed-point integers")
  end
  for _, field in ipairs(TERRAIN_SRT_ONES) do
    if type(srt[field]) ~= "boolean" then
      invalid("a material srt." .. field .. " must be a boolean")
    end
  end
end

-- The textureSwap record of one terrain material: the playback-group name
-- and the direct playback steps, each naming the replacement image for its
-- schedule entry and the entry's duration in ticks (zero durations are
-- valid: the source state machine can process them). The material's base
-- texture stays outside the schedule in material.texture, so no step is
-- compared against it.
local function checkTextureSwap(m, invalid)
  local swap = m.textureSwap
  if type(swap) ~= "table" or type(swap.name) ~= "string" or #swap.name == 0 then
    invalid("a material textureSwap requires a non-empty name")
  end
  local steps = swap.steps
  if not Validate.isArray(steps) or #steps == 0 then
    invalid("a material textureSwap requires a non-empty steps array")
  end
  for i, step in ipairs(steps) do
    local where = "a material textureSwap step " .. i .. " "
    if type(step) ~= "table" or type(step.texture) ~= "string" or #step.texture == 0 then
      invalid(where .. "must carry a non-empty texture path")
    end
    if not (isFiniteInteger(step.durationTicks) and step.durationTicks >= 0) then
      invalid(where .. "durationTicks must be a non-negative integer")
    end
  end
end

-- The terrain material fields: every material record carries the
-- texture-matrix inputs because the terrain animator is constructed
-- unconditionally -- textured materials have positive authored dimensions,
-- untextured materials zero or more (the producer emits zero), and only
-- texture-matrix mode 0 has a compiled convention. A textureSwap requires
-- the bound base texture the map starts from.
local function checkTerrainMaterial(m, invalid)
  local textured = type(m.texture) == "string"
  for _, field in ipairs({ "texWidth", "texHeight" }) do
    local value = m[field]
    if not isFiniteInteger(value) or (textured and value < 1) or (not textured and value < 0) then
      invalid("a material " .. field .. " must be a " .. (textured and "positive" or "non-negative") .. " integer")
    end
  end
  if m.texMtxMode ~= 0 then
    invalid("a material texMtxMode must be 0 (only the Maya texture-matrix convention is supported)")
  end
  local srt = m.srt
  if srt ~= nil then
    if type(srt) ~= "table" then
      invalid("a material srt must be a table")
    end
    checkTerrainSrt(srt, invalid)
  end
  if m.textureSwap ~= nil then
    if not textured then
      invalid("a textureSwap requires a base material texture")
    end
    checkTextureSwap(m, invalid)
  end
end

-- Two material records sharing one id in the same list are malformed: the id
-- identifies a material within its scene (central or per-neighbor list).
local function checkDuplicateMaterialIds(materials, invalid)
  local seen = {}
  for _, m in ipairs(materials) do
    if type(m) == "table" and m.id ~= nil then
      if seen[m.id] then
        invalid("two material records share the id " .. tostring(m.id) .. " in one list")
      end
      seen[m.id] = true
    end
  end
end

-- Collect every cache-relative path the scene references, recursing into model
-- descriptors (validated through ModelAsset) so a stale or missing model
-- geometry/texture is caught. The scene shape is validated strictly: the
-- current compiler always writes these fields, so malformed structure raises
-- MAP_CACHE_SCENE_INVALID instead of being defaulted to empty collections.
function MapAssetCache.referencedPaths(scene, cacheFs)
  local paths = {}

  local function invalid(reason)
    Errors.raise(AssetErrors.MAP_CACHE_SCENE_INVALID, "scene descriptor is malformed: " .. reason, { reason = reason })
  end

  if type(scene.terrainAnimations) ~= "table" then
    invalid("terrainAnimations is missing or not a table")
  end
  local textureSrt = scene.terrainAnimations.textureSrt
  if textureSrt ~= false then
    if type(textureSrt) ~= "table" then
      invalid("terrainAnimations.textureSrt must be false or a table")
    end
    CompiledNsbtaClip.validate(textureSrt, function(reason)
      invalid("terrainAnimations.textureSrt " .. reason)
    end)
  end

  if not Validate.isArray(scene.mapBatches) then
    invalid("mapBatches is not an array")
  end
  if not Validate.isArray(scene.materials) then
    invalid("materials is not an array")
  end
  if not Validate.isArray(scene.buildingInstances) then
    invalid("buildingInstances is not an array")
  end
  if not Validate.isArray(scene.neighbors) then
    invalid("neighbors is not an array")
  end

  if scene.terrain and type(scene.terrain) == "table" and scene.terrain.file then
    paths[#paths + 1] = scene.terrain.file
  end

  -- The runtime groups texture swaps by name, so every occurrence of one
  -- name must share its step count and per-step durations across the central
  -- scene and every neighbor cell; the texture paths may differ because
  -- neighboring cells compile the same animation against their own packs.
  local swapSchedules = {}
  local function checkSwapSchedule(m)
    local swap = m.textureSwap
    if swap == nil then
      return
    end
    local expected = swapSchedules[swap.name]
    if expected == nil then
      local durations = {}
      for _, step in ipairs(swap.steps) do
        durations[#durations + 1] = step.durationTicks
      end
      swapSchedules[swap.name] = { count = #swap.steps, durations = durations }
      return
    end
    if #swap.steps ~= expected.count then
      invalid("textureSwap " .. swap.name .. " carries a different step count than another material of the same name")
    end
    for i, step in ipairs(swap.steps) do
      if step.durationTicks ~= expected.durations[i] then
        invalid(
          "textureSwap " .. swap.name .. " carries different step durations than another material of the same name"
        )
      end
    end
  end

  local function addBatch(b)
    if type(b) ~= "table" or type(b.geometry) ~= "string" then
      invalid("a batch does not reference a geometry path")
    end
    paths[#paths + 1] = b.geometry
  end
  local function addMaterial(m)
    if type(m) ~= "table" or (m.texture ~= nil and type(m.texture) ~= "string") then
      invalid("a material is not a record with an optional texture path")
    end
    checkTerrainMaterial(m, invalid)
    checkSwapSchedule(m)
    if m.texture then
      paths[#paths + 1] = m.texture
    end
    if m.textureSwap then
      for _, step in ipairs(m.textureSwap.steps) do
        paths[#paths + 1] = step.texture
      end
    end
  end

  for _, b in ipairs(scene.mapBatches) do
    addBatch(b)
  end
  checkDuplicateMaterialIds(scene.materials, invalid)
  for _, m in ipairs(scene.materials) do
    addMaterial(m)
  end
  for _, cell in ipairs(scene.neighbors) do
    if type(cell) ~= "table" or not Validate.isArray(cell.batches) or not Validate.isArray(cell.materials) then
      invalid("a neighbor cell does not carry batches and materials arrays")
    end
    for _, b in ipairs(cell.batches) do
      addBatch(b)
    end
    checkDuplicateMaterialIds(cell.materials, invalid)
    for _, m in ipairs(cell.materials) do
      addMaterial(m)
    end
    if type(cell.collision) == "table" and cell.collision.file then
      paths[#paths + 1] = cell.collision.file
    end
    if type(cell.terrain) == "table" and cell.terrain.file then
      paths[#paths + 1] = cell.terrain.file
    end
  end
  for _, inst in ipairs(scene.buildingInstances) do
    if type(inst) ~= "table" or type(inst.modelKey) ~= "string" then
      invalid("a building instance does not carry a modelKey")
    end
    local modelPath = MapAssetCache.modelPath(inst.modelKey)
    paths[#paths + 1] = modelPath
    local desc = cacheFs and cacheFs:loadLua(modelPath)
    if type(desc) ~= "table" then
      invalid("model descriptor does not load: " .. inst.modelKey)
    end
    local ok, referenced = pcall(ModelAsset.referencedPaths, desc)
    if not ok then
      if Errors.is(referenced) and referenced.code == "MODEL_DESC_INVALID" then
        invalid("model descriptor is malformed: " .. inst.modelKey)
      end
      error(referenced)
    end
    for _, path in ipairs(referenced) do
      paths[#paths + 1] = path
    end
  end
  return paths
end

-- A collision asset is ready only when it exists and fully decodes as the
-- current project format: malformed magic/version/dimensions/blocked bytes
-- must never read as a valid grid.
local function validCollision(cacheFs, path)
  local bytes = cacheFs:read(path)
  if type(bytes) ~= "string" then
    return false
  end
  local grid = CollisionGridAsset.decode(bytes, { path = path })
  return grid ~= nil
end

-- True only if the marker is exact, the scene carries the current identity
-- (schema and mapId), scene/dependencies/terrain load, the collision asset
-- decodes (magic/version/dimensions/blocked bytes are all validated), every
-- model descriptor opens, and every referenced asset exists. A malformed
-- scene shape reports not ready rather than raising.
function MapAssetCache.isReady(cacheFs, mapId, expectedMarker)
  local dir = MapAssetCache.mapDir(mapId)
  local marker = cacheFs:read(dir .. "/complete")
  if marker ~= expectedMarker then
    return false
  end

  local scene = cacheFs:loadLua(dir .. "/scene.lua")
  if type(scene) ~= "table" then
    return false
  end
  if scene.schema ~= MapAssetCache.SCENE_SCHEMA or scene.mapId ~= mapId then
    return false
  end
  if not cacheFs:loadLua(dir .. "/dependencies.lua") then
    return false
  end
  local terrain = cacheFs:loadLua(MapAssetCache.terrainPath(mapId))
  if type(terrain) ~= "table" or terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
    return false
  end

  if not validCollision(cacheFs, MapAssetCache.collisionPath(mapId)) then
    return false
  end

  local ok, paths = pcall(MapAssetCache.referencedPaths, scene, cacheFs)
  if not ok then
    if
      Errors.is(paths)
      and (paths.code == AssetErrors.MAP_CACHE_SCENE_INVALID or paths.code == "MODEL_DESC_INVALID")
    then
      return false
    end
    error(paths)
  end
  for _, path in ipairs(paths) do
    if not cacheFs:exists(path) then
      return false
    end
  end
  for _, cell in ipairs(scene.neighbors) do
    if type(cell.collision) == "table" and cell.collision.file then
      if not validCollision(cacheFs, cell.collision.file) then
        return false
      end
    end
    if type(cell.terrain) == "table" and cell.terrain.file then
      local neighborTerrain = cacheFs:loadLua(cell.terrain.file)
      if type(neighborTerrain) ~= "table" or neighborTerrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
        return false
      end
    end
  end
  return true
end

function MapAssetCache.dependencies(cacheFs, mapId)
  return cacheFs:loadLua(MapAssetCache.mapDir(mapId) .. "/dependencies.lua")
end

return MapAssetCache
