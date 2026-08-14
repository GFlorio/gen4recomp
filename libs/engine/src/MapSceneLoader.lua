-- Turns the derived map cache into a visual runtime scene the renderer can
-- draw: it reads scene.lua, builds one persistent love Mesh per unique
-- `.g4mesh` path and one Image per unique (texture, wrap) sampler state (both
-- deduplicated through the shared GpuAssetPool, so repeated building models
-- and shared textures cost a single GPU object per sampler), wraps each
-- material's render state, resolves every placed building instance through
-- its model descriptor, and loads the scene's collision asset into a
-- CollisionGrid (the door-ownership pass resolves against it). A billboard
-- batch keeps its camera-independent base center and scale for the shader
-- instead of a baked camera-facing matrix. The build is the GPU-acquisition half
-- of scene loading: pure descriptor normalization (material wrap resolution,
-- the material-keyed sampler-wrap map, per-mesh centers/AABBs, model bounds
-- folds) lives in SceneDescriptor, and the pool mesh entry caches each
-- geometry path's center and AABB once, so no vertex rescan happens per draw
-- or placement.
-- All GPU construction happens here, once, never in draw; the pool releases
-- every owned mesh/image. Load is transactional: the whole build runs inside
-- pool:build(), so any failure -- a missing descriptor, an unsupported
-- transform mode -- releases every GPU object the construction acquired
-- before the error propagates. After load, a single lazy acquire failure
-- (resolveImage during live draw evaluation) releases only the object that
-- acquisition itself created, never the resources the live scene is drawing.
-- The runtime also exposes the scene's MapProps facade so field coordinates
-- resolve to placed doors and their semantic animations. The only ROM
-- knowledge that reaches this layer is the normalized scene descriptor; raw
-- Nitro formats stopped at the compiler.
--
-- The static and animated building draws are two independent runtime lists
-- (`staticBuildingDraws`, `animatedBuildingDraws`): the static list is built
-- once at load and never rebuilt, since nothing about a static placement
-- changes after load. The animated list is owned by the scene tick: every
-- fixed tick advances each attachment player and rebuilds ONLY the animated
-- items, unconditionally -- there is no dirty-forwarding layer, no
-- between-tick refresh, and no copying of the static list into the rebuild
-- (control ops like the door choreography run inside session ticks, so the
-- same or next tick's updateAnimated renders them). The renderer never
-- re-evaluates poses itself. Loading builds the frame-0 animated list
-- immediately, without advancing any animation clock, so the scene is
-- renderable the moment load returns.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")
local PoseContract = require("libs.assets.src.PoseContract")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local MapProps = require("libs.engine.src.MapProps")
local MapRenderer = require("libs.engine.src.MapRenderer")
local TimeOfDayProps = require("libs.engine.src.TimeOfDayProps")
local MeshWriter = require("libs.assets.src.MeshWriter")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local DoorTiles = require("libs.engine.src.DoorTiles")
local SceneDescriptor = require("libs.engine.src.SceneDescriptor")
local BillboardTransform = require("libs.engine.src.BillboardTransform")

local MapSceneLoader = {}

-- The identity UV-transform matrix of scene-form materials (they carry no
-- texture-SRT): the renderer reads the material's texMatrix directly.
local IDENTITY_TEX_MATRIX = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

local function isTranslationOnly(transform)
  return transform[1] == 1
    and transform[2] == 0
    and transform[3] == 0
    and transform[5] == 0
    and transform[6] == 1
    and transform[7] == 0
    and transform[9] == 0
    and transform[10] == 0
    and transform[11] == 1
end

local VALID_BANDS = {}
for _, band in ipairs(TimeOfDayProps.BANDS) do
  VALID_BANDS[band] = true
end

-- Material assembly: acquire each normalized material record's image
-- under its resolved sampler wrap. The wrap pair is part of the image
-- identity, so materials with the same pixels but different wraps resolve to
-- independent images. Scene-form materials carry no UV transform; the item
-- contract's material record provides the identity matrix.
local function materialsById(list, pool)
  local byId = {}
  for id, record in pairs(SceneDescriptor.materials(list)) do
    byId[id] = {
      id = record.id,
      name = record.name,
      image = pool:imageFor(record.texture, record.wrap.x, record.wrap.y),
      texMatrix = IDENTITY_TEX_MATRIX,
    }
  end
  return byId
end

-- Build the runtime scene against an already-created pool, inside the
-- build wrapper load() opens. Raises on any failure; the wrapper releases
-- the pool in that case. `opts.timeBand` seeds the time-of-day band
-- (default: the band of the default field time, noon = day); `opts.meshBuilder`
-- / `opts.imageBuilder` pass through to the pool (the GPU seams, injectable
-- in headless tests).
local function buildScene(pool, cacheFs, scene, opts)
  local timeBand = opts.timeBand or TimeOfDayProps.bandForSeconds(FieldLightProfile.DEFAULT_TIME_SECONDS)
  assert(VALID_BANDS[timeBand], "unknown time-of-day band " .. tostring(timeBand))
  local bounds = { min = { math.huge, math.huge, math.huge }, max = { -math.huge, -math.huge, -math.huge } }
  local modelNormals = {}

  -- A transform table is immutable scene data. Cache its model normal once
  -- for every static draw that shares it; translation-only transforms all
  -- share the module identity normal.
  local function modelNormalFor(transform)
    if isTranslationOnly(transform) then
      return IDENTITY_MODEL_NORMAL
    end
    local normal = modelNormals[transform]
    if not normal then
      normal = Matrix3.modelNormal(transform)
      modelNormals[transform] = normal
    end
    return normal
  end

  -- Grow the scene bounds by a model-space AABB under a placement transform
  -- (the image of the box is its eight transformed corners). The per-mesh
  -- AABBs come from the pool mesh entry (cached per geometry path), so the
  -- scene bounds are folds over cached boxes, never vertex rescans.
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

  -- Per-batch draw state that lives on the draw item, not the material
  -- record: the shared PolygonState schema the compiler emits on every batch
  -- (lightMask included), with polygonAlpha normalized to the renderer's
  -- 0..1 unit and the batch's compiled alpha class carried as-is.
  local function batchDrawState(batch)
    return {
      cullMode = batch.cullMode,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      polygonAlpha = batch.polygonAlpha / FixedPoint.RGB5_MAX,
      alphaClass = batch.alphaClass,
      alphaCutoff = AlphaClassifier.CUTOUT_EPSILON,
    }
  end

  -- One draw item for one batch under `instanceTransform` (identity for terrain,
  -- the placement matrix for a building). A billboard batch's geometry is in
  -- billboard-local space and its orientation depends on the camera, so the
  -- composed base supplies the shader's world center and scale; its static
  -- equivalent seeds `transform` and the scene bounds. Draw items carry no
  -- submission numbers: final queue traversal orders every part and draw in
  -- source order, positionally.
  local function drawItem(batch, materials, instanceTransform)
    local meshResource = pool:meshFor(batch.geometry)
    local billboardBase, billboardCenter, billboardScale
    if batch.transformMode == PoseContract.BILLBOARD then
      billboardBase =
        Matrix4.multiply(instanceTransform, assert(batch.baseTransform, "billboard batch is missing baseTransform"))
      billboardCenter, billboardScale = BillboardTransform.components(billboardBase)
    elseif batch.transformMode ~= nil then
      Errors.raise(
        FieldErrors.MAP_SCENE_UNSUPPORTED_TRANSFORM_MODE,
        "unknown batch transform mode " .. tostring(batch.transformMode),
        { transformMode = batch.transformMode, geometry = batch.geometry }
      )
    end
    local transform = billboardBase or instanceTransform
    growBoundsAabb(meshResource.bounds, transform)
    local state = batchDrawState(batch)
    return {
      mesh = meshResource.mesh,
      material = materials[batch.material],
      transform = transform,
      modelNormal = billboardBase and IDENTITY_MODEL_NORMAL or modelNormalFor(transform),
      billboardBase = billboardBase,
      billboardCenter = billboardCenter,
      billboardScale = billboardScale,
      alphaClass = state.alphaClass,
      cullMode = state.cullMode,
      alphaCutoff = state.alphaCutoff,
      polygonAlpha = state.polygonAlpha,
      polygonMode = state.polygonMode,
      lightMask = state.lightMask,
      polygonId = state.polygonId,
      translucentDepthWrite = state.translucentDepthWrite,
      depthEqual = state.depthEqual,
      center = meshResource.center,
    }
  end

  -- Map terrain draws: identity transform, materials from the scene list.
  local mapMaterials = materialsById(scene.materials, pool)
  local identity = Matrix4.identity()
  local mapDraws = {}
  for _, batch in ipairs(scene.mapBatches) do
    mapDraws[#mapDraws + 1] = drawItem(batch, mapMaterials, identity)
  end

  -- Placed building instances: resolve each modelKey's descriptor (batches +
  -- its own materials) and instance it at the placement transform. The
  -- descriptor cache entry also carries the model-space AABB of the model's
  -- geometry: the scene bounds grow it under each placement transform, and
  -- the placement records carry it for the scene's MapProps facade (the
  -- door index resolves by placement pivot, not by footprint).
  local descriptorCache = {}
  local function descriptorFor(modelKey)
    local cached = descriptorCache[modelKey]
    if not cached then
      local desc = assert(cacheFs:loadLua(MapAssetCache.modelPath(modelKey)), "missing model " .. modelKey)
      local mats = materialsById(desc.materials, pool)
      -- Pattern-variant textures are resolved lazily at evaluation time; the
      -- sampler state is keyed by material (never by texture path -- two
      -- materials can share one texture under different wraps), so the
      -- variant always samples with its own material's wrap.
      local wrapByMaterial = SceneDescriptor.wrapByMaterial(desc.materials)
      local batches
      if desc.kind == "static" then
        batches = desc.batches
      elseif desc.kind == "nitro-dynamic" then
        batches = desc.dynamic.batches
      else
        Errors.raise(
          FieldErrors.MAP_SCENE_UNKNOWN_MODEL_KIND,
          "model descriptor " .. modelKey .. " has unknown kind " .. tostring(desc.kind),
          { modelKey = modelKey, kind = desc.kind }
        )
      end
      -- The model-space AABB is a pure fold over the per-mesh entry bounds
      -- (cached on the pool entry per geometry path), one table per model
      -- shared by every placement record.
      local meshBounds = {}
      for _, batch in ipairs(batches) do
        meshBounds[#meshBounds + 1] = pool:meshFor(batch.geometry).bounds
      end
      cached = {
        descriptor = desc,
        materials = mats,
        wrapByMaterial = wrapByMaterial,
        bounds = SceneDescriptor.bounds(meshBounds),
      }
      descriptorCache[modelKey] = cached
    end
    return cached
  end

  local staticBuildingDraws = {}
  for _, inst in ipairs(scene.buildingInstances) do
    local desc = descriptorFor(inst.modelKey)
    -- Dynamic (animated) descriptors carry their geometry in the `dynamic`
    -- half; the static batches loop applies to baked descriptors only. The
    -- kind dispatch is explicit: a descriptor of an unknown kind is a
    -- generated-data failure, not a silent empty model.
    if desc.descriptor.kind == "static" then
      for _, batch in ipairs(desc.descriptor.batches) do
        staticBuildingDraws[#staticBuildingDraws + 1] = drawItem(batch, desc.materials, inst.transform)
      end
    elseif desc.descriptor.kind ~= "nitro-dynamic" then
      Errors.raise(
        FieldErrors.MAP_SCENE_UNKNOWN_MODEL_KIND,
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
  -- the instance handles (MapDoor/SceneProp).
  local animatedInstances = {}
  local instanceByPlacement = {}
  local animatedModelCount = 0
  local animatedResourceCache = {}
  for _, inst in ipairs(scene.buildingInstances) do
    local desc = descriptorFor(inst.modelKey)
    if desc.descriptor.kind == "nitro-dynamic" then
      local modelResource = animatedResourceCache[inst.modelKey]
      if not modelResource then
        local definition = ModelDefinition.fromNitroDescriptor(desc.descriptor, { key = inst.modelKey })
        local renderMeshesById = {}
        for _, mesh in ipairs(definition.meshes) do
          local meshResource = pool:meshFor(mesh.geometry)
          renderMeshesById[mesh.id] = meshResource.mesh
          mesh.center = meshResource.center
        end
        modelResource = { definition = definition, renderMeshesById = renderMeshesById }
        animatedResourceCache[inst.modelKey] = modelResource
        animatedModelCount = animatedModelCount + 1
      end
      local instance = ModelInstance.new(modelResource.definition, {
        transform = inst.transform,
        resolveImage = function(key, materialId)
          local wrap = assert(desc.wrapByMaterial[materialId], "missing wrap for animated texture " .. key)
          return pool:imageFor(key, wrap.x, wrap.y)
        end,
      })
      instance.renderMeshesById = modelResource.renderMeshesById
      growBoundsAabb(desc.bounds, inst.transform)
      animatedInstances[#animatedInstances + 1] = instance
      instanceByPlacement[inst.placementIndex] = instance
      local timeBandClips = TimeOfDayProps.plan(modelResource.definition)
      instance.timeOfDayPlan = timeBandClips
      if timeBandClips then
        local clip = timeBandClips[timeBand]
        if clip then
          instance:play(clip.name, { loopMode = "loop" })
        end
      else
        for _, clip in ipairs(modelResource.definition.animations) do
          if clip.ambientLoop then
            instance:play(clip.name, { loopMode = "loop" })
          end
        end
      end
    end
  end

  local runtime = {}

  -- The per-instance refresh pass shared by the tick update and the initial
  -- build: it re-evaluates each pose from the current attachment frames. The
  -- static building list is built once and never touched again -- only the
  -- animated list is rebuilt here, so a fixed tick's cost scales with the
  -- animated instance count, not the whole building set.
  local function refreshAnimatedItems()
    local items = {}
    for _, instance in ipairs(animatedInstances) do
      instance:evaluatePose()
      local drawn = instance:drawItems(instance.renderMeshesById)
      for _, item in ipairs(drawn) do
        items[#items + 1] = item
      end
    end
    runtime.animatedBuildingDraws = items
  end

  -- Advance every animated instance by one fixed step, then refresh: the one
  -- authoritative animation-clock entry point of the scene. The refresh is
  -- unconditional -- every tick rebuilds all animated items, so control ops
  -- never need to mark anything dirty.
  local function updateAnimated()
    for _, instance in ipairs(animatedInstances) do
      instance:updateFixed()
    end
    refreshAnimatedItems()
  end

  -- Switch the time-of-day band of every banded prop (HGSS ov01_022047DC):
  -- stop the previous band's clip, play the current band's clip looping.
  -- Re-setting the current band is a no-op. Unbanded instances are untouched.
  -- The swap does not mark the draw list dirty: the next scene tick rebuilds
  -- it unconditionally.
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
  runtime.staticBuildingDraws = staticBuildingDraws
  -- Build the frame-0 animated items inside the load build: the scene
  -- is renderable immediately after load, and the animation clocks never
  -- advanced (the first tick's updateAnimated starts them).
  refreshAnimatedItems()
  runtime.lighting = scene.lighting
  runtime.fieldTimeSeconds = FieldLightProfile.DEFAULT_TIME_SECONDS
  runtime.timeBand = timeBand
  runtime.animatedInstances = animatedInstances
  runtime.updateAnimated = updateAnimated
  runtime.setTimeBand = setTimeBand
  -- The door lookup: a MapProps facade over this scene's placements and
  -- instances resolves a field coordinate to the door of the building placed
  -- there -- nothing Nitro leaks into gameplay. Ownership over the scene's
  -- door tiles is precomputed here, once, from the nearest placement pivot.
  local placements = {}
  for _, inst in ipairs(scene.buildingInstances) do
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
    doorTiles = doorTiles,
  })
  runtime.stats = {
    meshCount = #pool.meshes,
    textureCount = #pool.images,
    triangleCount = pool.triangles,
    buildingInstances = #scene.buildingInstances,
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
      FieldErrors.MAP_SCENE_UNSUPPORTED_SCHEMA,
      "expected " .. MapAssetCache.SCENE_SCHEMA .. ", got " .. tostring(scene and scene.schema or nil),
      { schema = scene and scene.schema or nil }
    )
  end

  local pool = GpuAssetPool.new(cacheFs, opts)
  return pool:build(function()
    return buildScene(pool, cacheFs, scene, opts)
  end)
end

return MapSceneLoader
