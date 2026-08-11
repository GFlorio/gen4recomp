-- Turns the derived map cache into a visual runtime scene the renderer can
-- draw: it reads scene.lua, builds one persistent love Mesh per unique
-- `.g4mesh` path and one Image per unique (texture, wrap) sampler state (both
-- deduplicated through the shared GpuAssetPool, so repeated building models
-- and shared textures cost a single GPU object per sampler), wraps each
-- material's render state, resolves every placed building instance through
-- its model descriptor, and loads the scene's collision asset into a
-- CollisionGrid (the door-ownership pass resolves against it). A billboard
-- batch keeps the base transform the renderer resolves against the camera
-- each frame instead of a baked matrix. All GPU construction happens here,
-- once, never in draw; the pool releases every owned mesh/image. Load is
-- transactional: the pool guards its own acquires, and load() guards
-- everything after pool creation, so any failure -- a missing descriptor, an
-- unsupported transform mode -- releases every GPU object already acquired
-- before the error propagates. The runtime also exposes the scene's MapProps
-- facade so field coordinates resolve to placed doors and their semantic
-- animations. The only ROM knowledge that reaches this layer is the
-- normalized scene descriptor; raw Nitro formats stopped at the compiler.
--
-- The animated draw list is owned by one refresh pass: fixed ticks advance
-- every attachment player and rebuild the items once; control operations
-- (play/stop/band swap) mark the list dirty and the pre-render refresh
-- consumes it. The renderer never re-evaluates poses itself.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Matrix4 = require("libs.math.src.Matrix4")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local Errors = require("libs.errors.src.Errors")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")
local PoseContract = require("libs.engine.src.PoseContract")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")
local MapProps = require("libs.engine.src.MapProps")
local MapRenderer = require("libs.engine.src.MapRenderer")
local TimeOfDayProps = require("libs.engine.src.TimeOfDayProps")
local MeshWriter = require("libs.assets.src.MeshWriter")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local DoorTiles = require("libs.engine.src.DoorTiles")

local MapSceneLoader = {}

local VALID_BANDS = {}
for _, band in ipairs(TimeOfDayProps.bands()) do
  VALID_BANDS[band] = true
end

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
-- failure; load() releases the pool in that case. `opts.timeBand` seeds the
-- time-of-day band (default: the band of the default field time, noon =
-- day); `opts.meshBuilder` / `opts.imageBuilder` pass through to the pool
-- (the GPU seams, injectable in headless tests).
local function buildScene(pool, cacheFs, scene, opts)
  local timeBand = opts.timeBand or TimeOfDayProps.bandForSeconds(FieldLightProfile.DEFAULT_TIME_SECONDS)
  assert(VALID_BANDS[timeBand], "unknown time-of-day band " .. tostring(timeBand))
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

  -- Grow the scene bounds by a model-space AABB under a placement transform
  -- (the image of the box is its eight transformed corners).
  local function growBoundsAabb(aabb, transform)
    for i = 0, 1 do
      for j = 0, 1 do
        for k = 0, 1 do
          local x, y, z = Matrix4.transformPoint(
            transform,
            i == 1 and aabb.maxX or aabb.minX,
            j == 1 and aabb.maxY or aabb.minY,
            k == 1 and aabb.maxZ or aabb.minZ
          )
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
      alphaCutoff = MapRenderer.CUTOUT_EPSILON,
      polygonAlpha = batch.polygonAlpha ~= nil and (batch.polygonAlpha / 31) or 1.0,
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
    if batch.transformMode == PoseContract.BILLBOARD then
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
  -- its own materials) and instance it at the placement transform. The
  -- descriptor cache entry also carries the model-space AABB of the model's
  -- geometry: the footprint MapProps uses to resolve a door tile to the
  -- building whose footprint contains it.
  local descriptorCache = {}
  local function descriptorFor(modelKey)
    local cached = descriptorCache[modelKey]
    if not cached then
      local desc = assert(cacheFs:loadLua(MapAssetCache.modelPath(modelKey)), "missing model " .. modelKey)
      local mats = materialsById(desc.materials, pool)
      -- Pattern-variant textures are resolved lazily at evaluation time; map
      -- every texture key (base and variants) to its material's wrap so a
      -- variant never samples with the wrong wrap.
      local wrapByTexture = {}
      for _, record in ipairs(desc.materials or {}) do
        local wrap = record.wrap or { x = "clamp", y = "clamp" }
        if record.texture then
          wrapByTexture[record.texture] = wrap
        end
        for _, variant in ipairs(record.variants or {}) do
          if variant.texture then
            wrapByTexture[variant.texture] = wrap
          end
        end
      end
      local batches
      if desc.kind == "static" then
        batches = desc.batches
      elseif desc.kind == "nitro-dynamic" then
        batches = desc.dynamic.batches
      else
        Errors.raise(
          "MAP_SCENE_UNKNOWN_MODEL_KIND",
          "model descriptor " .. modelKey .. " has unknown kind " .. tostring(desc.kind),
          { modelKey = modelKey, kind = desc.kind }
        )
      end
      local aabb
      for _, batch in ipairs(batches) do
        local entry = pool:meshFor(batch.geometry)
        for _, v in ipairs(entry.verts) do
          if not aabb then
            aabb = { minX = v[1], maxX = v[1], minY = v[2], maxY = v[2], minZ = v[3], maxZ = v[3] }
          else
            aabb.minX = math.min(aabb.minX, v[1])
            aabb.maxX = math.max(aabb.maxX, v[1])
            aabb.minY = math.min(aabb.minY, v[2])
            aabb.maxY = math.max(aabb.maxY, v[2])
            aabb.minZ = math.min(aabb.minZ, v[3])
            aabb.maxZ = math.max(aabb.maxZ, v[3])
          end
        end
      end
      cached = {
        descriptor = desc,
        materials = mats,
        wrapByTexture = wrapByTexture,
        bounds = aabb or { minX = 0, maxX = 0, minY = 0, maxY = 0, minZ = 0, maxZ = 0 },
      }
      descriptorCache[modelKey] = cached
    end
    return cached
  end

  local buildingDraws = {}
  for _, inst in ipairs(scene.buildingInstances or {}) do
    local desc = descriptorFor(inst.modelKey)
    -- Dynamic (animated) descriptors carry their geometry in the `dynamic`
    -- half; the static batches loop applies to baked descriptors only. The
    -- kind dispatch is explicit: a descriptor of an unknown kind is a
    -- generated-data failure, not a silent empty model.
    if desc.descriptor.kind == "static" then
      for _, batch in ipairs(desc.descriptor.batches) do
        buildingDraws[#buildingDraws + 1] = drawItem(batch, desc.materials, inst.transform)
      end
    elseif desc.descriptor.kind ~= "nitro-dynamic" then
      Errors.raise(
        "MAP_SCENE_UNKNOWN_MODEL_KIND",
        "model descriptor " .. inst.modelKey .. " has unknown kind " .. tostring(desc.descriptor.kind),
        { modelKey = inst.modelKey, kind = desc.descriptor.kind }
      )
    end
  end

  -- ---- animated building instances ----

  -- An animated model descriptor (kind "nitro-dynamic") becomes a ModelInstance
  -- per placement: the definition is assembled from the serialized descriptor
  -- and the referenced .g4mesh batches become render meshes ONCE per model
  -- key, then every placement of that model shares them (model resource
  -- sharing). Each instance owns its animation state, material state, and
  -- pose -- two placements of one model can animate at different frames --
  -- while the definition and clips are immutable and shared.
  --
  -- Ambient playback at load: the compiled playback policy decides -- a
  -- time-of-day banded model plays the current band's clip looping and swaps
  -- on runtime:setTimeBand (HGSS ov01_022047DC); every clip of an
  -- ordinary-policy anim-list record carries the compiled ambientLoop role
  -- and plays looping (the field effects -- wind, machine, spring); other
  -- policy records (door pairs, interaction props) stay scripted through
  -- the controller.
  local animatedInstances = {}
  local instanceByPlacement = {}
  local animatedModelCount = 0
  local animatedResourceCache = {}
  for _, inst in ipairs(scene.buildingInstances or {}) do
    local desc = descriptorFor(inst.modelKey)
    if desc.descriptor.kind == "nitro-dynamic" then
      local entry = animatedResourceCache[inst.modelKey]
      if not entry then
        local definition = ModelDefinition.fromNitroDescriptor(desc.descriptor, { key = inst.modelKey })
        local renderMeshesById = {}
        for _, mesh in ipairs(definition.meshes) do
          local entry = pool:meshFor(mesh.geometry)
          renderMeshesById[mesh.id] = entry.mesh
          mesh.center = modelCenter(entry.verts)
        end
        entry = { definition = definition, renderMeshesById = renderMeshesById }
        animatedResourceCache[inst.modelKey] = entry
        animatedModelCount = animatedModelCount + 1
      end
      local instance = ModelInstance.new(entry.definition, {
        transform = inst.transform,
        resolveImage = function(key, width, height)
          return pool:imageFor(key, "clamp", "clamp")
        end,
      })
      instance.renderMeshesById = entry.renderMeshesById
      growBoundsAabb(desc.bounds, inst.transform)
      animatedInstances[#animatedInstances + 1] = instance
      instanceByPlacement[inst.placementIndex] = instance
      local timeBandClips = TimeOfDayProps.plan(entry.definition)
      instance.timeOfDayPlan = timeBandClips
      if timeBandClips then
        local clip = timeBandClips[timeBand]
        if clip then
          instance:play(clip.name, { loopMode = "loop" })
        end
      else
        for _, clip in ipairs(entry.definition.animations) do
          if clip.ambientLoop then
            instance:play(clip.name, { loopMode = "loop" })
          end
        end
      end
    end
  end

  local runtime = {}
  local staticBuildingDraws = buildingDraws
  local animatedItemsDirty = true

  -- The per-instance refresh pass shared by the update and dirty entries: it
  -- re-evaluates each pose from the current attachment frames, appends after
  -- the static building draws, and assigns each animated item a
  -- scene-global submission index continuing the load-time sequence.
  local function refreshAnimatedItems()
    local items = {}
    for _, item in ipairs(staticBuildingDraws) do
      items[#items + 1] = item
    end
    for _, instance in ipairs(animatedInstances) do
      instance:evaluatePose()
      local drawn = instance:drawItems(instance.renderMeshesById)
      for _, item in ipairs(drawn) do
        item.submissionIndex = #items
        items[#items + 1] = item
      end
    end
    runtime.buildingDraws = items
  end

  -- Advance every animated instance by one fixed step, then refresh: the one
  -- authoritative animation-clock entry point of the scene.
  local function updateAnimated()
    for _, instance in ipairs(animatedInstances) do
      instance:updateFixed()
    end
    refreshAnimatedItems()
    animatedItemsDirty = false
  end

  -- The pre-render refresh: consumes the dirty mark left by control
  -- operations (play/stop/band swap) that happened outside a fixed tick; the
  -- draw list is otherwise read-only, so the renderer never re-evaluates
  -- poses per frame.
  local function rebuildAnimatedDrawItems()
    if animatedItemsDirty then
      refreshAnimatedItems()
      animatedItemsDirty = false
    end
  end

  -- Switch the time-of-day band of every banded prop (HGSS ov01_022047DC):
  -- stop the previous band's clip, play the current band's clip looping.
  -- Re-setting the current band is a no-op. Unbanded instances are untouched.
  local function setTimeBand(self, band)
    assert(VALID_BANDS[band], "unknown time-of-day band " .. tostring(band))
    if runtime.timeBand == band then
      return
    end
    local previous = runtime.timeBand
    runtime.timeBand = band
    for _, instance in ipairs(animatedInstances) do
      if instance.timeOfDayPlan then
        TimeOfDayProps.swap(instance, instance.timeOfDayPlan, previous, band)
      end
    end
    animatedItemsDirty = true
  end

  -- Collision from the G4CL asset (CollisionGridAsset bytes), around the
  -- cell origin. Decoded through the same pure project-owned asset path the
  -- simulation-only loaders use, so the visual scene carries the grid the
  -- door-ownership pass resolves against.
  local collisionBytes = assert(cacheFs:read(scene.collision.file), "missing collision asset")
  local grid, decodeErr =
    CollisionGridAsset.decode(collisionBytes, { mapId = scene.mapId, path = scene.collision.file })
  assert(grid, decodeErr and decodeErr.message or "malformed collision asset")
  local collision = CollisionGrid.new(grid, {
    worldOriginX = scene.matrix.worldOriginX,
    worldOriginZ = scene.matrix.worldOriginZ,
  })

  -- The door tiles of this scene: every DOOR-kind (behavior 105) tile of
  -- the permission cell, as local indices. Door ownership is precomputed
  -- over exactly this list when the scene's MapProps is constructed --
  -- ambiguity and missing coverage are diagnosed once at load, never per
  -- lookup.
  local doorTiles = DoorTiles.fromGrid(collision)

  bounds.center = {
    (bounds.min[1] + bounds.max[1]) / 2,
    (bounds.min[2] + bounds.max[2]) / 2,
    (bounds.min[3] + bounds.max[3]) / 2,
  }

  runtime.scene = scene
  runtime.mapId = scene.mapId
  runtime.cameraType = scene.cameraType
  runtime.collision = collision
  runtime.bounds = bounds
  runtime.mapDraws = mapDraws
  runtime.buildingDraws = buildingDraws
  runtime.lighting = scene.lighting
  runtime.fieldTimeSeconds = FieldLightProfile.DEFAULT_TIME_SECONDS
  runtime.timeBand = timeBand
  runtime.animatedInstances = animatedInstances
  runtime.animationController = MapPropAnimationController.new()
  runtime.animationController.onMutation = function()
    animatedItemsDirty = true
  end
  runtime.rebuildAnimatedDrawItems = rebuildAnimatedDrawItems
  runtime.updateAnimated = updateAnimated
  runtime.setTimeBand = setTimeBand
  -- The door lookup: a MapProps facade over this scene's placements and
  -- instances resolves a field coordinate to the door of the building placed
  -- there -- nothing Nitro leaks into gameplay. Ownership over the scene's
  -- door tiles is precomputed here, once, from the nearest placement pivot.
  local placements = {}
  for _, inst in ipairs(scene.buildingInstances or {}) do
    placements[#placements + 1] = {
      placementIndex = inst.placementIndex,
      modelKey = inst.modelKey,
      transform = inst.transform,
      bounds = descriptorFor(inst.modelKey).bounds,
    }
  end
  runtime.mapProps = MapProps.new({
    placements = placements,
    instances = instanceByPlacement,
    controller = runtime.animationController,
    doorTiles = doorTiles,
  })
  runtime.stats = {
    meshCount = #pool.meshes,
    textureCount = #pool.images,
    triangleCount = pool.triangles,
    buildingInstances = #(scene.buildingInstances or {}),
    animatedInstances = #animatedInstances,
    animatedModelCount = animatedModelCount,
  }

  function runtime:release()
    pool:release()
  end

  return runtime
end

-- Load an assembled scene from the version's derived cache. `cacheFs` is a
-- CacheFs.forVersion; `scene` is the already-loaded scene.lua table. `opts`
-- passes through to the asset pool (opts.graphics: injectable graphics for
-- headless tests), and `opts.timeBand` / `opts.meshBuilder` seed the build
-- (see buildScene).
---@param cacheFs table
---@param scene table
---@param opts { graphics?: love.Graphics?, timeBand?: string, meshBuilder?: fun(decoded: table): any }?
---@return table
function MapSceneLoader.load(cacheFs, scene, opts)
  opts = opts or {}
  if not scene or scene.schema ~= MapAssetCache.SCENE_SCHEMA then
    Errors.raise(
      "MAP_SCENE_UNSUPPORTED_SCHEMA",
      "expected " .. MapAssetCache.SCENE_SCHEMA .. ", got " .. tostring(scene and scene.schema or nil),
      { schema = scene and scene.schema or nil }
    )
  end

  local pool = GpuAssetPool.new(cacheFs, opts)
  local ok, runtime = pcall(buildScene, pool, cacheFs, scene, opts)
  if not ok then
    pool:release()
    error(runtime)
  end
  return runtime
end

return MapSceneLoader
