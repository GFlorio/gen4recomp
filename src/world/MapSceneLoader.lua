-- Turns the derived map cache into a runtime scene the renderer can draw: it
-- reads scene.lua, builds one persistent love Mesh per unique .g4mesh and one
-- Image per unique texture (both deduplicated by content-addressed path so
-- repeated building models and shared textures cost a single GPU object), wraps
-- each material's render state, resolves every placed building instance through
-- its model descriptor, and loads permissions.bin into a CollisionGrid. All GPU
-- construction happens here, once, never in draw. release() frees every owned
-- mesh/image. The only ROM knowledge that reaches this layer is the normalized
-- scene descriptor; raw Nitro formats stopped at the compiler.

local SceneMesh = require("src.render.SceneMesh")
local VertexFormat = require("src.render.VertexFormat")
local PermissionGrid = require("src.data.PermissionGrid")
local CollisionGrid = require("src.world.CollisionGrid")
local MapAssetCache = require("src.core.MapAssetCache")
local Matrix4 = require("src.render.Matrix4")

local MapSceneLoader = {}

local function materialRuntime(record, imageFor)
  local d = record.diffuse or { r = 255, g = 255, b = 255, a = 255 }
  return {
    id = record.id,
    name = record.name,
    image = record.texture and imageFor(record.texture) or nil,
    diffuse = { d.r / 255, d.g / 255, d.b / 255, d.a / 255 },
    wrap = record.wrap or { x = "clamp", y = "clamp" },
    flip = record.flip or { x = false, y = false },
  }
end

-- Index a material list (map scene or model descriptor) by its zero-based id.
local function materialsById(list, imageFor)
  local byId = {}
  for _, record in ipairs(list or {}) do
    byId[record.id] = materialRuntime(record, imageFor)
  end
  return byId
end

-- Load an assembled scene from the version's derived cache. `cacheFs` is a
-- CacheFs.forVersion; `scene` is the already-loaded scene.lua table.
function MapSceneLoader.load(cacheFs, scene)
  assert(scene and scene.schema == "g4-map-scene-v2", "not a g4-map-scene-v2 descriptor")

  local meshCache, imageCache = {}, {}
  local owned = { meshes = {}, images = {} }
  local bounds = { min = { math.huge, math.huge, math.huge }, max = { -math.huge, -math.huge, -math.huge } }

  -- Grow the scene bounds by a batch's vertices under a placement transform.
  local function growBounds(verts, transform)
    for _, v in ipairs(verts) do
      local x, y, z = Matrix4.transformPoint(transform, v[1], v[2], v[3])
      if x < bounds.min[1] then bounds.min[1] = x end
      if y < bounds.min[2] then bounds.min[2] = y end
      if z < bounds.min[3] then bounds.min[3] = z end
      if x > bounds.max[1] then bounds.max[1] = x end
      if y > bounds.max[2] then bounds.max[2] = y end
      if z > bounds.max[3] then bounds.max[3] = z end
    end
  end

  -- Returns (mesh, decodedVertices); dedups by content-addressed path.
  local function meshFor(path)
    local entry = meshCache[path]
    if not entry then
      local decoded = SceneMesh.decode(assert(cacheFs:read(path), "missing mesh " .. path), path)
      entry = { mesh = SceneMesh.build(decoded), verts = decoded.vertices }
      meshCache[path] = entry
      owned.meshes[#owned.meshes + 1] = entry.mesh
      owned.triangles = (owned.triangles or 0) + decoded.indexCount / 3
    end
    return entry.mesh, entry.verts
  end

  local function imageFor(path)
    local image = imageCache[path]
    if not image then
      local bytes = assert(cacheFs:read(path), "missing texture " .. path)
      local data = love.filesystem.newFileData(bytes, "tex.png")
      image = love.graphics.newImage(data)
      image:setFilter("nearest", "nearest")
      imageCache[path] = image
      owned.images[#owned.images + 1] = image
    end
    return image
  end

  local function applyWrap(material)
    if material.image then
      local function mode(w) return w == "repeat" and "repeat" or "clamp" end
      material.image:setWrap(mode(material.wrap.x), mode(material.wrap.y))
    end
  end

  -- Per-batch draw state moved out of the material in slice 4.
  local function batchDrawState(batch)
    return {
      alphaClass = batch.alphaClass or "opaque",
      cullMode = batch.cullMode or "back",
      alphaCutoff = 0.5 / 255,
      polygonAlpha = batch.polygonAlpha ~= nil and (batch.polygonAlpha / 31) or 1.0,
      polygonMode = batch.polygonMode or "modulation",
      lightMask = batch.lightMask or 0,
      translucentDepthWrite = batch.translucentDepthWrite or false,
      depthEqual = batch.depthEqual or false,
    }
  end

  -- Map terrain draws: identity transform, materials from the scene list.
  local mapMaterials = materialsById(scene.materials, imageFor)
  for _, m in pairs(mapMaterials) do applyWrap(m) end
  local identity = Matrix4.identity()
  local mapDraws = {}
  for _, batch in ipairs(scene.mapBatches or {}) do
    local mesh, verts = meshFor(batch.geometry)
    growBounds(verts, identity)
    local state = batchDrawState(batch)
    mapDraws[#mapDraws + 1] = {
      mesh = mesh,
      material = mapMaterials[batch.material],
      transform = identity,
      alphaClass = state.alphaClass,
      cullMode = state.cullMode,
      alphaCutoff = state.alphaCutoff,
      polygonAlpha = state.polygonAlpha,
      polygonMode = state.polygonMode,
      lightMask = state.lightMask,
      translucentDepthWrite = state.translucentDepthWrite,
      depthEqual = state.depthEqual,
    }
  end

  -- Placed building instances: resolve each modelKey's descriptor (batches +
  -- its own materials) and instance it at the placement transform.
  local descriptorCache = {}
  local function descriptorFor(modelKey)
    local cached = descriptorCache[modelKey]
    if not cached then
      local desc = assert(cacheFs:loadLua(MapAssetCache.modelPath(modelKey)), "missing model " .. modelKey)
      local mats = materialsById(desc.materials, imageFor)
      for _, m in pairs(mats) do applyWrap(m) end
      cached = { batches = desc.batches, materials = mats }
      descriptorCache[modelKey] = cached
    end
    return cached
  end

  local buildingDraws = {}
  for _, inst in ipairs(scene.buildingInstances or {}) do
    local desc = descriptorFor(inst.modelKey)
    for _, batch in ipairs(desc.batches) do
      local mesh, verts = meshFor(batch.geometry)
      growBounds(verts, inst.transform)
      local state = batchDrawState(batch)
      buildingDraws[#buildingDraws + 1] = {
        mesh = mesh,
        material = desc.materials[batch.material],
        transform = inst.transform,
        alphaClass = state.alphaClass,
        cullMode = state.cullMode,
        alphaCutoff = state.alphaCutoff,
        polygonAlpha = state.polygonAlpha,
        polygonMode = state.polygonMode,
        lightMask = state.lightMask,
        translucentDepthWrite = state.translucentDepthWrite,
        depthEqual = state.depthEqual,
      }
    end
  end

  -- Collision from permissions.bin (2048 bytes), around the cell origin.
  local permBytes = assert(cacheFs:read(scene.collision.file), "missing permissions")
  local grid = assert(PermissionGrid.decode(permBytes, scene.mapSymbol))
  local collision = CollisionGrid.new(grid, {
    worldOriginX = scene.matrix.worldOriginX,
    worldOriginZ = scene.matrix.worldOriginZ,
  })

  bounds.center = {
    (bounds.min[1] + bounds.max[1]) / 2,
    (bounds.min[2] + bounds.max[2]) / 2,
    (bounds.min[3] + bounds.max[3]) / 2,
  }

  local runtime = {
    scene = scene,
    mapId = scene.mapId,
    label = scene.label,
    cameraType = scene.cameraType,
    collision = collision,
    bounds = bounds,
    mapDraws = mapDraws,
    buildingDraws = buildingDraws,
    stats = {
      meshCount = #owned.meshes,
      textureCount = #owned.images,
      triangleCount = owned.triangles or 0,
      buildingInstances = #(scene.buildingInstances or {}),
    },
  }

  function runtime:release()
    for _, mesh in ipairs(owned.meshes) do mesh:release() end
    for _, image in ipairs(owned.images) do image:release() end
    owned.meshes, owned.images = {}, {}
  end

  return runtime
end

return MapSceneLoader
