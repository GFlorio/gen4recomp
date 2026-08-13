-- Turns the derived map cache into a visual runtime scene the renderer can
-- draw: it reads scene.lua, builds one persistent love Mesh per unique
-- `.g4mesh` path and one Image per unique (texture, wrap) sampler state (both
-- deduplicated through the shared GpuAssetPool, so repeated building models
-- and shared textures cost a single GPU object per sampler), wraps each
-- material's render state, and resolves every placed building instance
-- through its model descriptor. Simulation facts (collision, terrain) are
-- owned by FieldMapLoader through the shared asset paths; this loader returns
-- no collision object. A billboard batch keeps the base transform the renderer
-- resolves against the camera each frame instead of a baked matrix. All GPU
-- construction happens here, once, never in draw; the pool releases every
-- owned mesh/image. Load is transactional: the pool guards its own acquires,
-- and load() guards everything after pool creation, so any failure -- a
-- missing descriptor, an unsupported transform mode -- releases every GPU
-- object already acquired before the error propagates. The only ROM knowledge
-- that reaches this layer is the normalized scene descriptor; raw Nitro
-- formats stopped at the compiler.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Matrix4 = require("libs.math.src.Matrix4")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local Errors = require("libs.errors.src.Errors")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")
local DsLighting = require("libs.engine.src.DsLighting")

local MapSceneLoader = {}

local function materialRuntime(record, pool)
  local wrap = record.wrap or { x = "clamp", y = "clamp" }
  return {
    id = record.id,
    name = record.name,
    image = pool:imageFor(record.texture, wrap.x, wrap.y),
  }
end

-- Index a material list (map scene or model descriptor) by its zero-based id.
-- The sampler state (wrap pair) is part of the image identity, so materials
-- with the same pixels but different wraps resolve to independent images.
local function materialsById(list, pool)
  local byId = {}
  for _, record in ipairs(list or {}) do
    byId[record.id] = materialRuntime(record, pool)
  end
  return byId
end

-- Build the runtime scene against an already-created pool. Raises on any
-- failure; load() releases the pool in that case.
local function buildScene(pool, cacheFs, scene)
  local bounds = { min = { math.huge, math.huge, math.huge }, max = { -math.huge, -math.huge, -math.huge } }

  -- Grow the scene bounds by a batch's vertices under a placement transform.
  local function growBounds(verts, transform)
    for _, v in ipairs(verts) do
      local x, y, z = Matrix4.transformPoint(transform, v[1], v[2], v[3])
      if x < bounds.min[1] then
        bounds.min[1] = x
      end
      if y < bounds.min[2] then
        bounds.min[2] = y
      end
      if z < bounds.min[3] then
        bounds.min[3] = z
      end
      if x > bounds.max[1] then
        bounds.max[1] = x
      end
      if y > bounds.max[2] then
        bounds.max[2] = y
      end
      if z > bounds.max[3] then
        bounds.max[3] = z
      end
    end
  end

  -- Bounding-box center of a mesh's vertices in model space.
  local function modelCenter(verts)
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
    return { (minx + maxx) / 2, (miny + maxy) / 2, (minz + maxz) / 2 }
  end

  -- Per-batch draw state that lives on the draw item, not the material record.
  local function batchDrawState(batch)
    return {
      alphaClass = batch.alphaClass or "opaque",
      cullMode = batch.cullMode or "back",
      alphaCutoff = 0.5 / 255,
      polygonAlpha = batch.polygonAlpha ~= nil and (batch.polygonAlpha / DsLighting.RGB5_MAX) or 1.0,
      polygonMode = batch.polygonMode or "modulation",
      lightMask = batch.lightMask or 0,
      polygonId = batch.polygonId or 0,
      translucentDepthWrite = batch.translucentDepthWrite or false,
      depthEqual = batch.depthEqual or false,
    }
  end

  -- One draw item for one batch under `instanceTransform` (identity for terrain,
  -- the placement matrix for a building). A billboard batch's geometry is in
  -- billboard-local space and its matrix depends on the camera, so the composed
  -- transform becomes `billboardBase` for the renderer to resolve each frame; its
  -- static equivalent seeds `transform` and the scene bounds. Draw items carry no
  -- submission numbers: the final scene assembly (SceneAssembly) orders every
  -- draw in source order, positionally.
  local function drawItem(batch, materials, instanceTransform)
    local entry = pool:meshFor(batch.geometry)
    local billboardBase
    if batch.transformMode == "billboard" then
      billboardBase =
        Matrix4.multiply(instanceTransform, assert(batch.baseTransform, "billboard batch is missing baseTransform"))
    elseif batch.transformMode ~= nil then
      Errors.raise(
        "MAP_SCENE_UNSUPPORTED_TRANSFORM_MODE",
        "unknown batch transform mode " .. tostring(batch.transformMode),
        { transformMode = batch.transformMode, geometry = batch.geometry }
      )
    end
    local transform = billboardBase or instanceTransform
    growBounds(entry.verts, transform)
    local state = batchDrawState(batch)
    return {
      mesh = entry.mesh,
      material = materials[batch.material],
      transform = transform,
      billboardBase = billboardBase,
      alphaClass = state.alphaClass,
      cullMode = state.cullMode,
      alphaCutoff = state.alphaCutoff,
      polygonAlpha = state.polygonAlpha,
      polygonMode = state.polygonMode,
      lightMask = state.lightMask,
      polygonId = state.polygonId,
      translucentDepthWrite = state.translucentDepthWrite,
      depthEqual = state.depthEqual,
      center = modelCenter(entry.verts),
    }
  end

  -- Map terrain draws: identity transform, materials from the scene list.
  local mapMaterials = materialsById(scene.materials, pool)
  local identity = Matrix4.identity()
  local mapDraws = {}
  for _, batch in ipairs(scene.mapBatches or {}) do
    mapDraws[#mapDraws + 1] = drawItem(batch, mapMaterials, identity)
  end

  -- Placed building instances: resolve each modelKey's descriptor (batches +
  -- its own materials) and instance it at the placement transform.
  local descriptorCache = {}
  local function descriptorFor(modelKey)
    local cached = descriptorCache[modelKey]
    if not cached then
      local desc = assert(cacheFs:loadLua(MapAssetCache.modelPath(modelKey)), "missing model " .. modelKey)
      cached = { batches = desc.batches, materials = materialsById(desc.materials, pool) }
      descriptorCache[modelKey] = cached
    end
    return cached
  end

  local buildingDraws = {}
  for _, inst in ipairs(scene.buildingInstances or {}) do
    local desc = descriptorFor(inst.modelKey)
    for _, batch in ipairs(desc.batches) do
      buildingDraws[#buildingDraws + 1] = drawItem(batch, desc.materials, inst.transform)
    end
  end

  -- Simulation facts (collision, terrain) are loaded by FieldMapLoader through
  -- the pure project-owned asset paths, never here.
  bounds.center = {
    (bounds.min[1] + bounds.max[1]) / 2,
    (bounds.min[2] + bounds.max[2]) / 2,
    (bounds.min[3] + bounds.max[3]) / 2,
  }

  local runtime = {
    scene = scene,
    mapId = scene.mapId,
    cameraType = scene.cameraType,
    bounds = bounds,
    mapDraws = mapDraws,
    buildingDraws = buildingDraws,
    lighting = scene.lighting,
    fieldTimeSeconds = FieldLightProfile.DEFAULT_TIME_SECONDS,
    stats = {
      meshCount = #pool.meshes,
      textureCount = #pool.images,
      triangleCount = pool.triangles,
      buildingInstances = #(scene.buildingInstances or {}),
    },
  }

  function runtime:release()
    pool:release()
  end

  return runtime
end

-- Load an assembled scene from the version's derived cache. `cacheFs` is a
-- CacheFs.forVersion; `scene` is the already-loaded scene.lua table; `opts`
-- passes through to the asset pool (injectable graphics for headless tests).
---@param cacheFs table
---@param scene table
---@param opts { graphics?: love.Graphics? }?
---@return table
function MapSceneLoader.load(cacheFs, scene, opts)
  if not scene or scene.schema ~= MapAssetCache.SCENE_SCHEMA then
    Errors.raise(
      "MAP_SCENE_UNSUPPORTED_SCHEMA",
      "expected " .. MapAssetCache.SCENE_SCHEMA .. ", got " .. tostring(scene and scene.schema or nil),
      { schema = scene and scene.schema or nil }
    )
  end

  local pool = GpuAssetPool.new(cacheFs, opts)
  local ok, runtime = pcall(buildScene, pool, cacheFs, scene)
  if not ok then
    pool:release()
    error(runtime)
  end
  return runtime
end

return MapSceneLoader
