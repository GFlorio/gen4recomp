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
local FieldViewport = require("libs.engine.src.FieldViewport")
local FieldSession = require("libs.engine.src.FieldSession")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.rom.src.LuaWriter")
local MeshWriter = require("libs.assets.src.MeshWriter")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local Hashing = require("romdump.src.digest.Hashing")

local T = {}

-- A 32x32 all-plain collision grid (the scene cell), optionally with one
-- DOOR-behavior (105) tile.
local function collisionGrid(doorTile)
  local cells = {}
  for index = 1, 32 * 32 do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  if doorTile then
    cells[doorTile.z * 32 + doorTile.x + 1] = { behavior = 105, terrainResponseId = 0, blocked = false }
  end
  return CollisionGridAsset.encode({ width = 32, height = 32, cells = cells })
end

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

local function identityMatrix()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
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
  local meshSha = Hashing.sha1hex(MeshWriter.encode(quad))
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
  clip.semanticNames = nil
  clip.timeBand = BAND_BY_SUFFIX[name:match("_(%a)$")]
  return clip
end

-- The door descriptor with the full open/close pair (the multi-clip shape:
-- nothing auto-plays; the controller scripts the roles).
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
-- referenced .g4mesh geometry into the cache.
local function sceneWith(instances, descriptors)
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
  backend:write(dir .. "/collision.g4collision", collisionGrid())
  return luaCache(backend)
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
    source = { type = "nitro", format = "NSBTP", archive = "build_anim", memberId = 3 },
    compiled = {
      numTextures = 1,
      numPalettes = 0,
      textureNames = { "v1" },
      paletteNames = {},
      targets = {
        {
          index = 0,
          name = "wall",
          rate = 0x1000,
          keyCount = 1,
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
  -- the scene starts with the bind-pose draw list and holds it until the
  -- controller scripts a role.
  local instance = runtime.animatedInstances[1]
  runtime:rebuildAnimatedDrawItems()
  Assert.equal(#runtime.buildingDraws, 1)
  local m0 = runtime.buildingDraws[1].transform

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

  -- The controller drives the semantic role on the loader-built instance.
  local controller = runtime.animationController
  controller:stop(instance, "door.open")
  controller:play(instance, "door.open")
  for _ = 1, 7 do
    instance:updateFixed()
  end
  Assert.isTrue(controller:isFinished(instance, "door.open"))

  -- The scene's door lookup resolves the loader-built instance from the door
  -- tile and drives the semantic door animation.
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
  local door = runtime.mapProps:doorAt(doorMap, 4, 14)
  assert(door)
  Assert.equal(door.instance, instance)
  Assert.equal(door.modelKey, "outdoor:26:door")
  door:open()
  for _ = 1, 7 do
    instance:updateFixed()
  end
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

  -- No ambient policy fires on a multi-clip model: the controller scripts
  -- the two instances in opposite directions. Independent control: b pauses
  -- mid-sequence while a runs to the end, so the shared definition cannot
  -- couple their playback.
  runtime.animationController:play(a, "door.open", { direction = 1 })
  runtime.animationController:play(b, "door.close", { direction = 1 })
  for _ = 1, 2 do
    a:updateFixed()
    b:updateFixed()
  end
  runtime.animationController:pause(b, "door.close")
  for _ = 1, 5 do
    a:updateFixed()
  end
  Assert.isTrue(runtime.animationController:isFinished(a, "door.open"))
  Assert.isFalse(runtime.animationController:isFinished(b, "door.close"))
  local aAttachment = a.animationState:attachments("joint")[1]
  local bAttachment = b.animationState:attachments("joint")[1]
  Assert.equal(aAttachment.clip.name, "door_op")
  Assert.equal(bAttachment.clip.name, "door_cl")
  Assert.isTrue(aAttachment.player.frameFx > bAttachment.player.frameFx)
  Assert.equal(bAttachment.player.frameFx, 2 * 4096, "the paused instance keeps its own frame")

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
  for _, category in ipairs({ "joint", "material", "visibility" }) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      names[#names + 1] = attachment.clip.name
    end
  end
  Assert.deepEqual(names, { "kk_sky_d" })

  -- A time-of-day change swaps the band (stop the old, play the new).
  runtime:setTimeBand("nite")
  Assert.equal(runtime.timeBand, "nite")
  names = {}
  for _, category in ipairs({ "joint", "material", "visibility" }) do
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
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local instance = runtime.animatedInstances[1]
  runtime.animationController:play(instance, "door.open")
  runtime:rebuildAnimatedDrawItems()
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

function T.draw_items_refresh_only_when_marked_dirty()
  local desc = doorPairDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local instance = runtime.animatedInstances[1]
  -- The first refresh consumes the initial dirty mark and builds the list;
  -- a second refresh is a no-op and keeps the item identity.
  runtime:rebuildAnimatedDrawItems()
  local draws = runtime.buildingDraws
  runtime:rebuildAnimatedDrawItems()
  Assert.isTrue(runtime.buildingDraws == draws, "a clean refresh keeps the cached list")
  -- A control op marks dirty; the next refresh rebuilds.
  runtime.animationController:play(instance, "door.open")
  runtime:rebuildAnimatedDrawItems()
  Assert.isFalse(runtime.buildingDraws == draws, "a control op marks the list dirty")
  -- A fixed tick advances the players and refreshes once.
  local drawsAfterUpdate = runtime.buildingDraws
  runtime:updateAnimated()
  Assert.isFalse(runtime.buildingDraws == drawsAfterUpdate, "updateAnimated rebuilds the items")
  Assert.equal(instance.animationState:attachments("joint")[1].player.frameFx, 4096)

  runtime:release()
end

-- The scene animation clock: FieldSession advances the loaded ambient props
-- exactly once per ordinary tick, and freezes them under a modal dialogue.
function T.ambient_clip_advances_once_per_session_tick_and_freezes_on_dialogue()
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
  Assert.isTrue(instance.animationState:hasAttachments("joint"), "the ambient clip autoplays at load")

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
      return false
    end,
  }
  local map = { mapId = 61, cameraType = 4, sceneRuntime = runtime }
  local camera = { updateFixed = function() end }
  local session = FieldSession.new({
    versionId = "heartgold",
    currentMap = map,
    actor = player,
    player = player,
    camera = camera,
  })

  session:updateFixed({})
  local attachment = instance.animationState:attachments("joint")[1]
  Assert.equal(attachment.player.frameFx, 4096, "one scene-animation advance per ordinary tick")
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 2 * 4096)

  -- A modal dialogue freezes the scene clock; the world's props stop.
  local dialogue = {
    isModal = function()
      return true
    end,
    step = function() end,
  }
  session.dialogue = dialogue
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 2 * 4096, "the modal tick does not advance the scene clock")
  session.dialogue = nil
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 3 * 4096, "the clock resumes when the dialogue closes")

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
  runtime:rebuildAnimatedDrawItems()
  local image = runtime.buildingDraws[1].material.image
  Assert.notNil(image, "the animated material resolves an image")
  Assert.equal(image.path, desc.materials[1].texture)
  Assert.deepEqual(image.wraps, { { "repeat", "repeat" } }, "the image is requested with the material's wrap")
  Assert.equal(runtime.stats.textureCount, 1)
  runtime:release()
end

-- A pattern variant texture is resolved with the SAME wrap as its material:
-- wrapByTexture maps every variant texture key to the owning material's
-- wrap, so a variant never samples with the wrong sampler.
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
  runtime:rebuildAnimatedDrawItems()
  local baseImage = runtime.buildingDraws[1].material.image
  Assert.deepEqual(baseImage.wraps, { { "repeat", "repeat" } }, "the base texture uses the material's wrap")

  -- The pattern selects the variant; the variant resolves with the same wrap.
  -- The controller play marks the scene's draw list dirty; the next refresh
  -- (the pre-render rebuild after one update) consumes it.
  runtime.animationController:play(instance, "pattern")
  instance:updateFixed()
  runtime:rebuildAnimatedDrawItems()
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
  runtime:rebuildAnimatedDrawItems()
  Assert.isNil(runtime.buildingDraws[1].material.image)
  -- Even while a clip plays, an untextured material never resolves an image.
  runtime.animationController:play(runtime.animatedInstances[1], "door.open")
  runtime.animatedInstances[1]:updateFixed()
  runtime:rebuildAnimatedDrawItems()
  Assert.equal(#images, 0, "playing an untextured clip never touches the image pool")
  runtime:release()
end

return {
  metadata = { layer = "graphics", capabilities = { "graphics" } },
  tests = T,
}
