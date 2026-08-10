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

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Matrix4 = require("libs.math.src.Matrix4")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local Errors = require("libs.errors.src.Errors")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")
local DsLighting = require("libs.engine.src.DsLighting")
local SceneMesh = require("libs.engine.src.SceneMesh")
local PoseContract = require("libs.engine.src.PoseContract")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")
local MapProps = require("libs.engine.src.MapProps")
local TimeOfDayProps = require("libs.engine.src.TimeOfDayProps")
local PosePerformanceCounter = require("libs.engine.src.PosePerformanceCounter")
local RuntimeAllocationProfiler = require("libs.engine.src.RuntimeAllocationProfiler")
local MeshWriter = require("libs.assets.src.MeshWriter")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local CollisionGrid = require("libs.engine.src.CollisionGrid")

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
-- failure; load() releases the pool in that case. `opts.meshBuilder`
-- replaces SceneMesh.build (the GPU seam, injectable in headless tests) and
-- `opts.timeBand` seeds the time-of-day band (default: the band of the
-- default field time, noon = day).
local function buildScene(pool, cacheFs, scene, opts)
  local buildMesh = opts.meshBuilder or SceneMesh.build
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
  -- its own materials) and instance it at the placement transform. The raw
  -- descriptor stays on the cached entry: the animated path builds a
  -- ModelDefinition from it (the `dynamic` half, clips, and raw material
  -- records), while the static path consumes the pre-built batches and the
  -- pool's material records.
  local descriptorCache = {}
  local function descriptorFor(modelKey)
    local cached = descriptorCache[modelKey]
    if not cached then
      local desc = assert(cacheFs:loadLua(MapAssetCache.modelPath(modelKey)), "missing model " .. modelKey)
      -- The full descriptor stays attached: the animated half (`dynamic`)
      -- and the compiled clips live on it, not in the static batch cache.
      cached = {
        descriptor = desc,
        batches = desc.batches,
        materials = materialsById(desc.materials, pool),
      }
      descriptorCache[modelKey] = cached
    end
    return cached
  end

  local buildingDraws = {}
  for _, inst in ipairs(scene.buildingInstances or {}) do
    local desc = descriptorFor(inst.modelKey)
    -- Dynamic (animated) descriptors carry their geometry in the `dynamic`
    -- half; the static batches loop applies to baked descriptors only.
    for _, batch in ipairs(desc.batches or {}) do
      buildingDraws[#buildingDraws + 1] = drawItem(batch, desc.materials, inst.transform)
    end
  end

  -- ---- animated building instances ----

  -- An animated model descriptor (backend "nitro" with a `dynamic` half)
  -- becomes a ModelInstance per placement: the definition is assembled from
  -- the serialized descriptor and the dynamic G4M3 batches become render
  -- meshes ONCE per model key, then every placement of that model shares
  -- them (model resource sharing, spec section 39). Each instance owns its
  -- animation state, material state, and pose -- two placements of one model
  -- can animate at different frames -- while the definition and clips are
  -- immutable and shared.
  --
  -- Ambient playback at load: a model with exactly one animation clip plays
  -- it looping (the field effects -- wind, machine, spring); a time-of-day
  -- banded model (clips named *_m/_d/_e/_n) plays the current band's clip
  -- looping and swaps on runtime:setTimeBand (HGSS ov01_022047DC); other
  -- multi-clip models (doors) stay scripted through the controller.
  local animatedInstances = {}
  local instanceByPlacement = {}
  local animatedModelCount = 0
  local animatedResourceCache = {}
  -- Pose-performance counters and per-tick allocation counters for the
  -- animated scene (spec section 39): ModelInstance records its pose and
  -- material evaluations into `perf` keyed by the instance; the scene passes
  -- below record the update/band-swap phases and the sync totals.
  local perf = PosePerformanceCounter.new()
  local alloc = RuntimeAllocationProfiler.new()
  for _, inst in ipairs(scene.buildingInstances or {}) do
    local desc = descriptorFor(inst.modelKey)
    if desc.descriptor.dynamic then
      local entry = animatedResourceCache[inst.modelKey]
      if not entry then
        local definition = ModelDefinition.fromNitroDescriptor(desc.descriptor, { key = inst.modelKey })
        local renders = {}
        for _, mesh in ipairs(definition.meshes) do
          -- Rigid Nitro batches carry no skin attributes (see
          -- MeshWriter.ensureSkinAttributes); stamp them before the strict encode.
          MeshWriter.ensureSkinAttributes(mesh.batch.vertices)
          local bytes = MeshWriter.encode(mesh.batch, { format = "g4m3" })
          local decoded = SceneMesh.decode(bytes)
          renders[mesh.id] = pool:adoptMesh(buildMesh(decoded), decoded.indexCount / 3)
        end
        entry = { definition = definition, renders = renders }
        animatedResourceCache[inst.modelKey] = entry
        animatedModelCount = animatedModelCount + 1
      end
      local instance = ModelInstance.new(entry.definition, {
        transform = inst.transform,
        performance = perf,
        resolveImage = function(key, width, height)
          return pool:imageFor(key, "clamp", "clamp")
        end,
      })
      instance.renders = entry.renders
      instance.placementIndex = inst.placementIndex
      animatedInstances[#animatedInstances + 1] = instance
      instanceByPlacement[inst.placementIndex] = instance
      local plan = TimeOfDayProps.plan(entry.definition)
      instance.timeOfDayPlan = plan
      if plan then
        local clip = plan[timeBand]
        if clip then
          instance:play(clip.name, { loopMode = "loop" })
        end
      elseif #entry.definition.animations == 1 then
        instance:play(entry.definition.animations[1].name, { loopMode = "loop" })
      end
    end
  end

  -- Refresh the animated instances' draw items from their current pose and
  -- material state; appends after the static building draws.
  local staticBuildingDraws = buildingDraws
  local runtime = {}

  -- The per-instance refresh pass shared by the sync and update entries:
  -- pose + items are the allocation sites of the per-frame hot path.
  local function refreshAnimatedItems()
    local items = {}
    for _, item in ipairs(staticBuildingDraws) do
      items[#items + 1] = item
    end
    for _, instance in ipairs(animatedInstances) do
      instance:evaluatePose()
      alloc:add("pose")
      local drawn = instance:drawItems(instance.renders)
      alloc:add("items", #drawn)
      for _, item in ipairs(drawn) do
        items[#items + 1] = item
      end
    end
    runtime.buildingDraws = items
  end

  -- The per-frame draw entry (the renderer calls it every frame): one
  -- allocation tick covering the refresh, timed as the scene's sync phase.
  local function syncAnimatedDraws()
    alloc:beginTick()
    local t0 = perf.clock()
    refreshAnimatedItems()
    perf:record(nil, PosePerformanceCounter.SYNC, perf.clock() - t0)
    alloc:endTick()
  end

  -- Advance every animated instance by one fixed step, then refresh; the
  -- update counts share the tick with the draw pass.
  local function updateAnimated()
    alloc:beginTick()
    local t0 = perf.clock()
    for _, instance in ipairs(animatedInstances) do
      local u0 = perf.clock()
      instance:updateFixed()
      perf:record(instance, PosePerformanceCounter.UPDATE, perf.clock() - u0)
      alloc:add("update")
    end
    refreshAnimatedItems()
    perf:record(nil, PosePerformanceCounter.SYNC, perf.clock() - t0)
    alloc:endTick()
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
        perf:record(instance, PosePerformanceCounter.BAND_SWAP, 0)
      end
    end
    syncAnimatedDraws()
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
  runtime.syncAnimatedDraws = syncAnimatedDraws
  runtime.updateAnimated = updateAnimated
  runtime.setTimeBand = setTimeBand
  -- Observability (spec section 39): the scene's pose-performance counters
  -- and the per-tick allocation counters of the animation path.
  runtime.perf = perf
  runtime.alloc = alloc
  -- The door lookup: a MapProps facade over this scene's placements and
  -- instances resolves a field coordinate to the door of the building placed
  -- there -- nothing Nitro leaks into gameplay.
  runtime.mapProps = MapProps.new({
    placements = scene.buildingInstances or {},
    instances = instanceByPlacement,
    controller = runtime.animationController,
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
