-- Scene-loader animation path tests: a scene whose building instance
-- references an animated (dynamic) model descriptor loads through
-- MapSceneLoader into a ModelInstance, advances with the scene runtime, and
-- renders through MapRenderer. The descriptor shape is the compiler's:
-- explicit schema/kind, dynamic batches referencing content-addressed .g4mesh
-- geometry, compiled clips with playback policy (timeBand / ambientLoop).
-- The rendering tests build real GPU resources, so the whole suite declares
-- the graphics layer and the runner skips it explicitly on hosts without one.

local Assert = require("tests.support.Assert")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldGrid = require("libs.engine.src.FieldGrid")
local FieldViewport = require("libs.engine.src.FieldViewport")
local FieldSession = require("libs.engine.src.FieldSession")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.MeshWriter")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")

local T = {}

-- A 32x32 all-plain collision grid (the scene cell), optionally with
-- DOOR-behavior (105) tiles. `doorTiles` is either one { x, z } tile or a
-- list of them.
local function collisionGrid(doorTiles)
  local cells = {}
  for index = 1, 32 * 32 do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  local function mark(tile)
    cells[tile.z * 32 + tile.x + 1] = { behavior = 105, terrainResponseId = 0, blocked = false }
  end
  if doorTiles then
    if doorTiles.z ~= nil then
      mark(doorTiles)
    else
      for _, tile in ipairs(doorTiles) do
        mark(tile)
      end
    end
  end
  return CollisionGridAsset.encode({ width = 32, height = 32, cells = cells })
end

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

local function identityMatrix()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

-- The transform of a door placement at the door tile (4,14)'s centre -- the
-- tile the door fixtures enumerate, so the placement sits within the
-- corpus-backed door-ownership bound (the scene fixture's cell origin is
-- (0,0)).
local function doorTransform()
  local wx, wz = FieldGrid.tileCenterToWorld(4, 14)
  local transform = identityMatrix()
  transform[13] = wx
  transform[15] = wz
  return transform
end

-- The in-memory cache facade over a FakeCache backend: loadLua reads and
-- evals in an empty environment, like CacheFs.loadLua.
local function luaCache(backend)
  local function loadLua(path)
    local data = assert(backend:read(path), "missing cache file " .. path)
    local chunk = assert(loadstring(data, path))
    setfenv(chunk, {})
    local ok, result = pcall(chunk)
    assert(ok, result)
    return result
  end
  return {
    read = function(_, path)
      return backend:read(path)
    end,
    loadLua = function(_, path)
      return loadLua(path)
    end,
  }
end

-- The 2x2-tile quad in tile space (MeshWriter vertex shape).
local function doorQuad()
  local function v(x, z)
    return {
      x = x,
      y = 0,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end
  return {
    vertices = { v(0, 0), v(2, 0), v(2, 2), v(0, 2) },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
end

local function doorProgram()
  return {
    name = "wk_door3",
    scalingRule = 0,
    posScale = 1,
    invPosScale = 1,
    tileScale = 1 / 16,
    nodes = {
      {
        index = 0,
        matrixStackIndex = 0,
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
        transZero = true,
        rotZero = true,
        scaleOne = true,
      },
    },
    commands = {
      { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
      { opcode = 0x02, nodeIndex = 0, visible = true },
      { opcode = 0x04, materialIndex = 0 },
      { opcode = 0x05, shapeIndex = 0 },
      { opcode = 0x01 },
    },
    evpMatrices = nil,
  }
end

-- A compiled NSBCA-style pivot rotation clip (pivot A = 1 - i/16, B = i/16,
-- like the real `door_op`).
local function swingClip(id, name, semantic)
  local rotData = {}
  for i = 0, 7 do
    rotData[i + 1] = { control = 0x0024, a = 4096 - i * 256, b = i * 256 }
  end
  local keys = {}
  for i = 0, 7 do
    keys[i + 1] = 0x8000 + i
  end
  return {
    id = id,
    name = name,
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = semantic and { semantic } or {},
    source = { type = "nitro", format = "NSBCA", archive = "build_anim", memberId = 1 },
    compiled = {
      anmFlags = 0,
      rotData = rotData,
      pivotData = {},
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
            rot = { source = "curve", rate = 1, limit = 8, storage = "fx16", keys = keys },
            scale = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
          },
        },
      },
    },
  }
end

-- The serialized dynamic descriptor shape MapAssetCompiler writes for an
-- animated building: an 8-frame door with a compiled NSBCA pivot rotation.
-- The dynamic batches reference the content-addressed .g4mesh path of the
-- encoded quad; the fixture writes those bytes into the cache alongside.
local function doorDescriptor()
  local quad = doorQuad()
  -- Content-addressed key: the same literal the fixture writes the encoded
  -- quad under (the geometry path is arbitrary within this test).
  local meshSha = "mesh_door_quad_0000000000000000000000000000000000"
  return {
    schema = "g4-model-v2",
    key = "outdoor:26:door",
    memberId = 26,
    kind = "nitro-dynamic",
    dynamic = {
      nodes = {
        {
          index = 0,
          matrixStackIndex = 0,
          translation = { x = 0, y = 0, z = 0 },
          rotation = identity9(),
          scale = { x = 1, y = 1, z = 1 },
          transZero = true,
          rotZero = true,
          scaleOne = true,
        },
      },
      transformProgram = doorProgram(),
      batches = {
        {
          id = "draw0.seg0",
          drawIndex = 0,
          segmentIndex = 0,
          nodeIndex = 0,
          materialIndex = 0,
          transformMode = "static",
          positionSource = "draw",
          geometry = MapAssetCache.geometryPath(meshSha),
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
          lightMask = 5,
        },
      },
    },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
        polygonAlpha = 31,
        texMtxMode = 0,
        texWidth = 0,
        texHeight = 0,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
      },
    },
    animations = { swingClip("build_anim-1", "door_op", "door.open") },
  }
end

-- The door descriptor's single clip re-parameterized: a banded-sky clip
-- (the compiled record stays a valid NSBCA pivot).
local BAND_BY_SUFFIX = { m = "morn", d = "day", e = "eve", n = "nite" }

local function skyClipRecord(name)
  local base = assert(doorDescriptor()).animations[1]
  local clip = {}
  for k, v in pairs(base) do
    clip[k] = v
  end
  clip.id = "sky:" .. name
  clip.name = name
  clip.semanticNames = {}
  clip.timeBand = BAND_BY_SUFFIX[name:match("_(%a)$")]
  return clip
end

-- The door descriptor with the full open/close pair (the multi-clip shape:
-- nothing auto-plays; the door choreography scripts the roles).
local function doorPairDescriptor()
  local desc = doorDescriptor()
  local close = skyClipRecord("door_cl")
  close.id = "build_anim-2"
  close.semanticNames = { "door.close" }
  close.timeBand = nil
  desc.animations[2] = close
  return desc
end

-- A banded model descriptor: the door's program with four time-of-day clips
-- (kk_sky_m/d/e/n, the corpus naming convention).
local function skyDescriptor()
  local desc = doorDescriptor()
  desc.key = "indoor:113:sky"
  desc.memberId = 113
  desc.animations = {
    skyClipRecord("kk_sky_m"),
    skyClipRecord("kk_sky_d"),
    skyClipRecord("kk_sky_e"),
    skyClipRecord("kk_sky_n"),
  }
  return desc
end

-- A single non-door clip: the compiled ambient role (the field effects --
-- wind, machine, spring).
local function ambientDescriptor()
  local desc = doorDescriptor()
  desc.key = "outdoor:7:wind"
  desc.memberId = 7
  local clip = swingClip("build_anim-3", "wind", nil)
  clip.ambientLoop = true
  desc.animations = { clip }
  return desc
end

-- A minimal scene with the given building instances over the given model
-- descriptors, in the loader test fixture shape. Writes each descriptor's
-- referenced .g4mesh geometry into the cache. `doorTiles` (optional local
-- indices) marks the listed tiles with the DOOR behavior (105) in the
-- permission cell, so the loader's MapProps precomputes door ownership over
-- them.
local function sceneWith(instances, descriptors, doorTiles)
  local mapId = 61
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(mapId)
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    versionId = "heartgold",
    mapId = mapId,
    mapSymbol = "MAP_NEW_BARK",
    matrix = {
      memberId = 0,
      name = "map",
      width = 1,
      height = 1,
      x = 0,
      z = 0,
      index = 0,
      altitude = 0,
      worldOriginX = 0,
      worldOriginZ = 0,
    },
    area = {
      memberId = 2,
      type = "outdoor",
      mapTexturePackId = 0,
      buildingTexturePackId = 0,
      dynamicTextureType = 0,
      lightType = 0,
    },
    collision = { width = 32, height = 32, file = dir .. "/collision.g4collision" },
    mapBatches = {},
    materials = {},
    buildingInstances = instances,
    neighbors = {},
    lighting = nil,
  }
  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  for _, desc in pairs(descriptors) do
    backend:write(MapAssetCache.modelPath(desc.key), LuaWriter.encode(desc))
    if desc.kind == "nitro-dynamic" then
      for _, batch in ipairs(desc.dynamic.batches) do
        backend:write(batch.geometry, MeshWriter.encode(doorQuad()))
      end
    end
  end
  backend:write(dir .. "/collision.g4collision", collisionGrid(doorTiles))
  return luaCache(backend)
end

-- The runtime-map shape doorAt consumes for a loader-built runtime: the
-- loader's collision is the permission grid, the cell origin is (0,0) (the
-- fixture matrix), and the door tile carries a warp record.
local function doorMapFor(runtime, x, z)
  return {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = {
      events = {
        warps = {
          { index = 0, x = x, z = z, destinationMapId = 60, destinationWarpId = 0, y = 0 },
        },
      },
    },
    collision = runtime.collision,
  }
end

-- A fake mesh builder for the loader's GPU seam: SceneMesh.decode output
-- becomes a plain object, so the loader's assembly, sharing, and playback
-- policy run headless.
local function fakeMeshBuilder(decoded)
  return {
    id = decoded and decoded.name or "mesh",
    release = function() end,
  }
end

-- A fake image builder that RECORDS the sampler configuration: the pool
-- configures every image it builds with image:setWrap(wrapX, wrapY), so the
-- recorded wrap pair is the observable imageFor request. `images` collects
-- the built objects in build order, each tagged with its texture path.
local function recordingImageBuilder(images)
  return function(path)
    local image = { path = path, wraps = {} }
    image.setFilter = function() end
    image.setWrap = function(_, wrapX, wrapY)
      image.wraps[#image.wraps + 1] = { wrapX, wrapY }
    end
    image.release = function() end
    images[#images + 1] = image
    return image
  end
end

-- The door descriptor with a textured material: base texture (64x64) plus
-- optional pattern variants, sampled under the material's wrap pair. The
-- loader maps every texture key (base and variants) to the material's wrap
-- for the animated resolveImage path; the fixture pins that the resolve
-- requests carry the precomputed wrap, never an unconditional clamp.
local function texturedDescriptor(opts)
  opts = opts or {}
  local desc = doorDescriptor()
  desc.key = "outdoor:26:texdoor"
  desc.memberId = 26
  local material = desc.materials[1]
  material.texture = opts.baseTexture or MapAssetCache.texturePath("texbase")
  material.texWidth = 64
  material.texHeight = 64
  material.textureFormat = 3
  material.alphaUsage = { hasZero = true }
  material.wrap = opts.wrap or { x = "repeat", y = "repeat" }
  material.variants = opts.variants
  desc.animations = opts.animations or desc.animations
  return desc
end

-- A compiled NSBTP-style pattern clip selecting the first variant at frame 0.
local function patternClip()
  return {
    id = "build_anim-3",
    name = "pattern",
    category = "material",
    kind = "pattern",
    frameCount = 8,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBTP", archive = "build_anim", memberId = 3 },
    compiled = {
      textureNames = { "v1" },
      paletteNames = {},
      targets = {
        {
          index = 0,
          name = "wall",
          rate = 0x1000,
          keys = { { frame = 0, texIdx = 0, plttIdx = 0xFF } },
        },
      },
    },
  }
end

function T.animated_building_loads_advances_and_renders()
  local mapId = 61
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(mapId)
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    versionId = "heartgold",
    mapId = mapId,
    mapSymbol = "MAP_NEW_BARK",
    matrix = {
      memberId = 0,
      name = "map",
      width = 1,
      height = 1,
      x = 0,
      z = 0,
      index = 0,
      altitude = 0,
      worldOriginX = 0,
      worldOriginZ = 0,
    },
    area = {
      memberId = 2,
      type = "outdoor",
      mapTexturePackId = 0,
      buildingTexturePackId = 0,
      dynamicTextureType = 0,
      lightType = 0,
    },
    collision = { width = 32, height = 32, file = dir .. "/collision.g4collision" },
    mapBatches = {},
    materials = {},
    buildingInstances = {
      {
        placementIndex = 0,
        modelKey = "outdoor:26:door",
        -- The door model is placed at the door tile (4,14)'s centre, which
        -- the door lookup measures against.
        transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -11.5, 0, -1.5, 1 },
      },
    },
    neighbors = {},
    lighting = nil,
  }
  local descriptor = doorDescriptor()
  local modelPath = MapAssetCache.modelPath("outdoor:26:door")

  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  backend:write(modelPath, LuaWriter.encode(descriptor))
  for _, batch in ipairs(descriptor.dynamic.batches) do
    backend:write(batch.geometry, MeshWriter.encode(doorQuad()))
  end
  -- The door tile (4,14) carries DOOR behavior (105); everything else is
  -- plain floor, so the door lookup resolves the placed door model.
  backend:write(dir .. "/collision.g4collision", collisionGrid({ x = 4, z = 14 }))

  local cache = luaCache(backend)
  local runtime = MapSceneLoader.load(cache, scene)
  Assert.equal(runtime.stats.animatedInstances, 1)
  Assert.equal(#runtime.animatedInstances, 1)

  -- The door is scripted (its clip carries a door role, not ambientLoop);
  -- loading still produces the frame-0 renderable draw list immediately --
  -- the animated item exists without any tick -- and the animation clock
  -- has not advanced.
  local instance = runtime.animatedInstances[1]
  Assert.equal(#runtime.buildingDraws, 1, "the animated door item exists right after load")
  local m0 = runtime.buildingDraws[1].transform
  -- The animated draw items carry the compiled per-segment polygon state:
  -- the light mask survives descriptor -> definition -> drawItems on the
  -- loader-assembled animated model.
  Assert.equal(runtime.buildingDraws[1].lightMask, 5, "the animated door item carries its polygon light mask")

  -- Advance and sync: a scripted door holds its bind pose.
  for _ = 1, 7 do
    runtime:updateAnimated()
  end
  local m7 = runtime.buildingDraws[1].transform
  for i = 1, 16 do
    Assert.near(m0[i], m7[i], 1e-3, "a scripted door holds its bind pose until played")
  end

  -- The production renderer draws the animated door. The renderer takes the
  -- flattened scene list; the loader's sync refreshed runtime.buildingDraws.
  local renderer = MapRenderer.new()
  local identity = identityMatrix()
  local camera = {
    distance = 26,
    view = function()
      return identity
    end,
    projection = function()
      return identity
    end,
    billboardProjection = function()
      return identity
    end,
  }
  renderer:draw(runtime, camera, runtime.buildingDraws, FieldViewport.new(320, 240, { mode = "strict" }), 1)
  Assert.isTrue(renderer.stats.drawCalls >= 1, "the animated door draws")

  -- The handle surface drives the semantic role on the loader-built
  -- instance: play returns the live attachment, whose player reaches the
  -- checked-advance terminal (numFrame * FRAME_UNIT) exactly.
  local handle = instance:play("door.open", { loopMode = "once" })
  Assert.equal(type(handle), "table", "play returns the attachment handle")
  Assert.equal(handle.clip.name, "door_op")
  for _ = 1, 7 do
    instance:updateFixed()
  end
  Assert.isFalse(handle.player:isComplete(), "the checked advance is not done before the terminal")
  instance:updateFixed()
  Assert.isTrue(handle.player:isComplete())

  local doorMap = {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = {
      events = {
        warps = {
          { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 },
        },
      },
    },
    collision = runtime.collision,
  }
  -- The scene's door lookup resolves the loader-built instance from the door
  -- tile and drives the semantic door animation (the manual play above is
  -- stopped first: one attachment per kind, so the door replay must not
  -- stack).
  instance:stop(handle)
  local door = runtime.mapProps:doorAt(doorMap, 4, 14)
  assert(door)
  Assert.equal(door.instance, instance)
  Assert.equal(door.modelKey, "outdoor:26:door")
  door:open()
  for _ = 1, 7 do
    instance:updateFixed()
  end
  Assert.isFalse(door:isFinished(), "the checked advance is not done before the terminal")
  instance:updateFixed()
  Assert.isTrue(door:isFinished(), "the loader-resolved door opens to completion")

  renderer:release()
  runtime:release()
end

function T.shared_definitions_share_resources_and_isolate_state()
  local desc = doorPairDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = identityMatrix(),
    },
    {
      placementIndex = 1,
      modelKey = "outdoor:26:door",
      transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 0, 0, 1 },
    },
  }, { [desc.key] = desc })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  Assert.equal(runtime.stats.animatedInstances, 2)
  Assert.equal(runtime.stats.animatedModelCount, 1, "one definition serves both placements")

  local a, b = runtime.animatedInstances[1], runtime.animatedInstances[2]
  Assert.isTrue(a.definition == b.definition, "placements share the model definition")
  Assert.isTrue(a.renderMeshesById == b.renderMeshesById, "placements share the render meshes")
  Assert.isFalse(a.materialState == b.materialState, "material state is per instance")

  -- No ambient policy fires on a multi-clip model: the handles drive the
  -- two instances forward independently. Independent control: b is
  -- advanced two ticks while a runs to the checked-advance terminal, so
  -- the shared definition cannot couple their playback.
  local aHandle = a:play("door.open", { loopMode = "once" })
  local bHandle = b:play("door.close", { loopMode = "once" })
  for _ = 1, 2 do
    a:updateFixed()
    b:updateFixed()
  end
  for _ = 1, 6 do
    a:updateFixed()
  end
  Assert.isTrue(aHandle.player:isComplete())
  Assert.isFalse(bHandle.player:isComplete())
  Assert.equal(aHandle.clip.name, "door_op")
  Assert.equal(bHandle.clip.name, "door_cl")
  Assert.equal(aHandle.player.frameFx, 8 * 4096, "the terminal is exactly numFrame * FRAME_UNIT")
  Assert.isTrue(aHandle.player.frameFx > bHandle.player.frameFx)
  Assert.equal(bHandle.player.frameFx, 2 * 4096, "the independent handle keeps its own frame")

  runtime:release()
end

function T.banded_model_plays_its_time_band_and_swaps()
  local desc = skyDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "indoor:113:sky",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )

  -- Noon is the default field time: the day band plays at load.
  local instance = runtime.animatedInstances[1]
  Assert.equal(runtime.timeBand, "day")
  Assert.isTrue(instance.timeOfDayPlan ~= nil, "the banded model carries its band plan")
  local names = {}
  for _, category in ipairs({ "joint", "material" }) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      names[#names + 1] = attachment.clip.name
    end
  end
  Assert.deepEqual(names, { "kk_sky_d" })
  Assert.equal(
    instance.animationState:attachments("joint")[1].player.frameFx,
    0,
    "load starts the day band at frame 0 without advancing the clock"
  )

  -- A time-of-day change swaps the band (stop the old, play the new).
  runtime:setTimeBand("nite")
  Assert.equal(runtime.timeBand, "nite")
  names = {}
  for _, category in ipairs({ "joint", "material" }) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      names[#names + 1] = attachment.clip.name
    end
  end
  Assert.deepEqual(names, { "kk_sky_n" })

  -- The swapped band advances with the scene.
  runtime:updateAnimated()
  local attachment = instance.animationState:attachments("joint")[1]
  Assert.equal(attachment.clip.name, "kk_sky_n")
  Assert.equal(attachment.player.frameFx, 4096)

  -- Re-setting the same band is a no-op (the clip keeps its frame).
  runtime:setTimeBand("nite")
  runtime:updateAnimated()
  Assert.equal(attachment.player.frameFx, 2 * 4096)

  runtime:release()
end

-- The fixed tick re-evaluates each instance's pose from its attachment
-- frames: after a play, the scene's draw items track the swing (this is the
-- headless guarantee behind the graphics-gated render test).
function T.update_advances_the_pose_driven_draw_items()
  local desc = doorDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = doorTransform(),
    },
  }, { [desc.key] = desc }, { { x = 4, z = 14 } })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local instance = runtime.animatedInstances[1]
  local door = assert(runtime.mapProps:doorAt(doorMapFor(runtime, 4, 14), 4, 14))
  door:open()
  runtime:updateAnimated()
  local m0 = runtime.buildingDraws[1].transform
  for _ = 1, 7 do
    runtime:updateAnimated()
  end
  local m7 = runtime.buildingDraws[1].transform
  local differs = false
  for i = 1, 16 do
    if math.abs(m0[i] - m7[i]) > 1e-3 then
      differs = true
    end
  end
  Assert.isTrue(differs, "the scrubbed door draw differs from frame 0")
  runtime:release()
end

-- The scene's draw list refreshes on the scene TICK, not on control ops:
-- every animation tick (FieldSession -> updateAnimated) rebuilds all
-- animated items unconditionally, and nothing between ticks consumes a
-- refresh -- so there is no dirty-forwarding layer. A play
-- between ticks leaves the cached list untouched; the next tick rebuilds
-- it.
function T.draw_items_refresh_only_on_the_scene_tick()
  local desc = doorPairDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = doorTransform(),
    },
  }, { [desc.key] = desc }, { { x = 4, z = 14 } })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local instance = runtime.animatedInstances[1]
  -- The load-time build already produced the frame-0 draw list; a control
  -- op between ticks marks nothing: the cached list stays until the scene
  -- tick rebuilds it.
  local draws = runtime.buildingDraws
  instance:play("door.open")
  runtime:updateAnimated()
  Assert.isFalse(runtime.buildingDraws == draws, "updateAnimated rebuilds the items")
  Assert.equal(instance.animationState:attachments("joint")[1].player.frameFx, 4096)

  runtime:release()
end

-- The scene animation clock: FieldSession advances the loaded ambient props
-- exactly once per tick -- ordinary ticks and modal-dialogue ticks alike. The
-- HGSS field update path does not couple map-prop animation progression to
-- dialogue ownership, so wind/machines keep running while a message box is
-- up. Only the world steps freeze under the modal gate: movement, warps, pose
-- clocks, and the camera; the dialogue still owns the tick for its own
-- stepping.
function T.ambient_clip_advances_once_per_session_tick_and_through_dialogue()
  local desc = ambientDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:7:wind",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local instance = runtime.animatedInstances[1]
  Assert.isTrue(#instance.animationState:attachments("joint") == 1, "the ambient clip autoplays at load")

  local playerSteps, cameraSteps = 0, 0
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      playerSteps = playerSteps + 1
      return false
    end,
  }
  local map = { mapId = 61, cameraType = 4, sceneRuntime = runtime }
  local camera = {
    updateFixed = function()
      cameraSteps = cameraSteps + 1
    end,
  }
  local inactiveDialogue = {
    isModal = function()
      return false
    end,
  }
  local session = FieldSession.new({
    versionId = "heartgold",
    currentMap = map,
    player = player,
    camera = camera,
    transition = {
      locked = false,
      updateFixed = function() end,
      start = function() end,
    },
    actors = { step = function() end },
    input = {
      snapshot = function()
        return {}
      end,
    },
    dialogue = inactiveDialogue,
    scriptScheduler = {
      step = function() end,
      playerMovementLocked = function()
        return false
      end,
    },
    scriptClient = { consume = function() end },
    menuHost = {
      isModal = function()
        return false
      end,
      advance = function() end,
    },
    contextChoice = {
      isActive = function()
        return false
      end,
    },
    interactions = {
      resolve = function()
        return nil
      end,
    },
  })

  session:updateFixed({})
  local attachment = instance.animationState:attachments("joint")[1]
  Assert.equal(attachment.player.frameFx, 4096, "one scene-animation advance per ordinary tick")
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 2 * 4096)

  -- Count only the modal phase below: the two ordinary ticks already stepped
  -- the player and camera; the modal gate's freeze covers the ticks it owns.
  playerSteps, cameraSteps = 0, 0

  -- A modal dialogue freezes the world steps but not the scene clock: the
  -- ambient props advance once per modal tick, exactly as on locked
  -- transition ticks, while the dialogue alone reads the input.
  local dialogueSteps = 0
  local dialogue = {
    isModal = function()
      return true
    end,
    step = function()
      dialogueSteps = dialogueSteps + 1
    end,
  }
  session.dialogue = dialogue
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 3 * 4096, "the modal tick advances the scene clock once")
  Assert.equal(dialogueSteps, 1, "the dialogue still owns the modal tick's stepping")
  Assert.equal(playerSteps, 0, "the modal tick does not move the player")
  Assert.equal(cameraSteps, 0, "the modal tick does not move the camera")
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 4 * 4096, "the scene clock keeps advancing while the box is up")
  Assert.equal(dialogueSteps, 2)
  Assert.equal(playerSteps, 0)
  Assert.equal(cameraSteps, 0)
  session.dialogue = inactiveDialogue
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 5 * 4096, "the ordinary tick cadence resumes when the dialogue closes")

  -- Script-owned boxes keep their exemption: the script scheduler steps them
  -- from its own async phase, so the modal gate does not apply and the world
  -- -- scene clock included -- runs normally.
  local scriptOwned = {
    isModal = function()
      return true
    end,
    isScriptOwned = function()
      return true
    end,
    step = function() end,
  }
  session.dialogue = scriptOwned
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 6 * 4096, "a script-owned box keeps the world running")

  runtime:release()
end

function T.load_rejects_an_unknown_initial_band()
  local desc = skyDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "indoor:113:sky",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local ok, err = pcall(
    MapSceneLoader.load,
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, timeBand = "bogus" }
  )
  Assert.isFalse(ok)
  assert(tostring(err):find("unknown time-of-day band", 1, true) ~= nil, tostring(err))
end

-- The animated (dynamic) image path must honor the material's sampler wrap:
-- an animated material with a repeat wrap resolves through the pool with
-- repeat/repeat, never the unconditional clamp/clamp of the old callback.
function T.animated_material_resolves_its_image_with_the_material_wrap()
  local desc = texturedDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:texdoor",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local images = {}
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, imageBuilder = recordingImageBuilder(images) }
  )
  runtime:updateAnimated()
  local image = runtime.buildingDraws[1].material.image
  Assert.notNil(image, "the animated material resolves an image")
  Assert.equal(image.path, desc.materials[1].texture)
  Assert.deepEqual(image.wraps, { { "repeat", "repeat" } }, "the image is requested with the material's wrap")
  Assert.equal(runtime.stats.textureCount, 1)
  runtime:release()
end

-- A pattern variant texture is resolved with the SAME wrap as its material:
-- the sampler state is keyed by material id, so a variant never samples
-- with the wrong sampler.
function T.animated_variant_texture_uses_the_material_wrap()
  local variantTexture = MapAssetCache.texturePath("texvariant")
  local desc = texturedDescriptor({
    variants = {
      {
        name = "v1",
        texture = variantTexture,
        width = 32,
        height = 32,
        textureFormat = 7,
      },
    },
    animations = { patternClip() },
  })
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:texdoor",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local images = {}
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, imageBuilder = recordingImageBuilder(images) }
  )
  local instance = runtime.animatedInstances[1]

  -- The base texture first: the material's wrap applies to the base too.
  runtime:updateAnimated()
  local baseImage = runtime.buildingDraws[1].material.image
  Assert.deepEqual(baseImage.wraps, { { "repeat", "repeat" } }, "the base texture uses the material's wrap")

  -- The pattern selects the variant; the variant resolves with the same wrap.
  -- The pattern play attaches the clip; the next scene tick advances it and
  -- refreshes the draw items, so the rebuild sees the switched texture.
  instance:play("pattern")
  runtime:updateAnimated()
  local variantImage = runtime.buildingDraws[1].material.image
  Assert.equal(variantImage.path, variantTexture, "the pattern switches to the variant texture")
  Assert.deepEqual(variantImage.wraps, { { "repeat", "repeat" } }, "the variant texture uses its material's wrap")
  runtime:release()
end

-- Untextured animated materials never touch the image pool: the resolveImage
-- callback only fires for a material with a current texture.
function T.untextured_animated_materials_never_request_an_image()
  local desc = doorDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local images = {}
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, imageBuilder = recordingImageBuilder(images) }
  )
  Assert.equal(#images, 0, "no image is requested for an untextured material")
  Assert.equal(runtime.stats.textureCount, 0)
  runtime:updateAnimated()
  Assert.isNil(runtime.buildingDraws[1].material.image)
  -- Even while a clip plays, an untextured material never resolves an image.
  local instance = runtime.animatedInstances[1]
  instance:play("door.open")
  runtime:updateAnimated()
  Assert.equal(#images, 0, "playing an untextured clip never touches the image pool")
  runtime:release()
end

return {
  metadata = { layer = "graphics", capabilities = { "graphics" } },
  tests = T,
}
