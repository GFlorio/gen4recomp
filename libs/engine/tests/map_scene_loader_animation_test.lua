-- LÖVE smoke test for the production scene-loader animation path: a scene
-- whose building instance references an animated (dynamic) model descriptor
-- loads through MapSceneLoader into a ModelInstance, advances with the
-- scene runtime, and renders through MapRenderer. Skips itself without a
-- graphics context like the other renderer smoke tests.

local Assert = require("tests.support.Assert")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldViewport = require("libs.engine.src.FieldViewport")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.rom.src.LuaWriter")

local T = {}

local function hasGraphics()
  return love and love.graphics and love.graphics.newShader
end

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

-- The serialized dynamic descriptor shape MapAssetCompiler writes for an
-- animated building: an 8-frame door with a compiled NSBCA pivot rotation.
local function doorDescriptor()
  local rotData = {}
  for i = 0, 7 do
    rotData[i + 1] = { control = 0x0024, a = 4096 - i * 256, b = i * 256 }
  end
  local keys = {}
  for i = 0, 7 do
    keys[i + 1] = 0x8000 + i
  end
  return {
    key = "outdoor:26:door",
    memberId = 26,
    backend = "nitro",
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
      transformProgram = {
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
      },
      batches = {
        {
          id = "draw0.seg0",
          drawIndex = 0,
          segmentIndex = 0,
          nodeIndex = 0,
          materialIndex = 0,
          transformMode = "static",
          positionSource = "draw",
          batch = {
            vertices = {
              {
                x = 0,
                y = 0,
                z = 0,
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
                joints = { 0, 0, 0, 0 },
                weights = { 0, 0, 0, 0 },
              },
              {
                x = 2,
                y = 0,
                z = 0,
                u = 1,
                v = 0,
                nx = 0,
                ny = 1,
                nz = 0,
                r = 255,
                g = 255,
                b = 255,
                a = 255,
                colorSource = 0,
                joints = { 0, 0, 0, 0 },
                weights = { 0, 0, 0, 0 },
              },
              {
                x = 2,
                y = 2,
                z = 0,
                u = 1,
                v = 1,
                nx = 0,
                ny = 1,
                nz = 0,
                r = 255,
                g = 255,
                b = 255,
                a = 255,
                colorSource = 0,
                joints = { 0, 0, 0, 0 },
                weights = { 0, 0, 0, 0 },
              },
              {
                x = 0,
                y = 2,
                z = 0,
                u = 0,
                v = 1,
                nx = 0,
                ny = 1,
                nz = 0,
                r = 255,
                g = 255,
                b = 255,
                a = 255,
                colorSource = 0,
                joints = { 0, 0, 0, 0 },
                weights = { 0, 0, 0, 0 },
              },
            },
            indices = { 0, 1, 2, 0, 2, 3 },
          },
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
      },
    },
    animations = {
      {
        id = "exterior_build_anim_list-1",
        name = "door_op",
        category = "joint",
        kind = "trs",
        frameCount = 8,
        tracks = { { target = 0, targetIndex = 0 } },
        semanticNames = { "door.open" },
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
      },
    },
    roles = { ["door.open"] = "door_op" },
  }
end

local function identityMatrix()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

function T.animated_building_loads_advances_and_renders()
  if not hasGraphics() then
    return
  end
  local mapId = 61
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(mapId)
  local scene = {
    schema = "g4-map-scene-v3",
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
    collision = { width = 32, height = 32, file = dir .. "/permissions.bin" },
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
  local modelPath = MapAssetCache.modelPath("outdoor:26:door")

  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  backend:write(modelPath, LuaWriter.encode(doorDescriptor()))
  -- The door tile (4,14) carries DOOR behavior (105); everything else is
  -- plain floor, so the door lookup resolves the placed door model.
  local permissions = string.rep("\0", 2048)
  local doorOffset = (14 * 32 + 4) * 2 + 1
  permissions = permissions:sub(1, doorOffset) .. string.char(105) .. permissions:sub(doorOffset + 2)
  backend:write(dir .. "/permissions.bin", permissions)

  local cache = {
    read = function(_, path)
      return backend:read(path)
    end,
    loadLua = function(_, path)
      return backend:loadLua(path)
    end,
  }
  local runtime = MapSceneLoader.load(cache, scene)
  Assert.equal(runtime.stats.animatedInstances, 1)
  Assert.equal(#runtime.animatedInstances, 1)

  -- The ambient policy plays the single clip looping.
  local instance = runtime.animatedInstances[1]
  runtime:syncAnimatedDraws()
  Assert.equal(#runtime.buildingDraws, 1)
  local m0 = runtime.buildingDraws[1].transform

  -- Advance and sync: the door swings.
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
    permissions = runtime.collision,
  }
  local door = assert(runtime.mapProps:doorAt(doorMap, 4, 14))
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
-- The door descriptor's single clip re-parameterized: a banded-sky clip
-- (name/id swapped; the compiled record stays a valid NSBCA pivot).
local function skyClipRecord(name)
  local base = assert(doorDescriptor()).animations[1]
  local clip = {}
  for k, v in pairs(base) do
    clip[k] = v
  end
  clip.id = "sky:" .. name
  clip.name = name
  clip.semanticNames = nil
  return clip
end

-- The door descriptor with the full open/close pair (the multi-clip shape:
-- nothing auto-plays; the controller scripts the roles).
local function doorPairDescriptor()
  local desc = doorDescriptor()
  local close = skyClipRecord("door_cl")
  close.id = "exterior_build_anim_list-2"
  close.semanticNames = { "door.close" }
  desc.animations[2] = close
  desc.roles = { ["door.open"] = "door_op", ["door.close"] = "door_cl" }
  return desc
end

-- A banded model descriptor: the door's program with four time-of-day clips
-- (kk_sky_m/d/e/n, the corpus naming convention).
local function skyDescriptor()
  local desc = doorDescriptor()
  desc.key = "indoor:113:sky"
  desc.animations = {
    skyClipRecord("kk_sky_m"),
    skyClipRecord("kk_sky_d"),
    skyClipRecord("kk_sky_e"),
    skyClipRecord("kk_sky_n"),
  }
  desc.roles = {}
  return desc
end

-- A minimal scene with the given building instances over the given model
-- descriptors, in the loader test fixture shape.
local function sceneWith(instances, descriptors)
  local mapId = 61
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(mapId)
  local scene = {
    schema = "g4-map-scene-v3",
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
    collision = { width = 32, height = 32, file = dir .. "/permissions.bin" },
    mapBatches = {},
    materials = {},
    buildingInstances = instances,
    neighbors = {},
    lighting = nil,
  }
  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  for _, desc in pairs(descriptors) do
    backend:write(MapAssetCache.modelPath(desc.key), LuaWriter.encode(desc))
  end
  backend:write(dir .. "/permissions.bin", string.rep("\0", 2048))
  -- loadLua over the in-memory backend: read + eval in an empty environment,
  -- like CacheFs.loadLua.
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

-- A fake mesh builder for the loader's GPU seam: SceneMesh.decode output
-- becomes a plain object, so the loader's assembly, sharing, and playback
-- policy run headless.
local function fakeMeshBuilder(decoded)
  return {
    id = decoded and decoded.name or "mesh",
    release = function() end,
  }
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
  Assert.isTrue(a.renders == b.renders, "placements share the render meshes")
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

function T.scene_exposes_pose_performance_and_allocation_counters()
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
  local perf, alloc = runtime.perf, runtime.alloc
  assert(perf, "the scene exposes pose-performance counters")
  assert(alloc, "the scene exposes the allocation profiler")
  local a, b = runtime.animatedInstances[1], runtime.animatedInstances[2]
  Assert.equal(a.placementIndex, 0, "the loader tags instances with their placement")
  Assert.equal(b.placementIndex, 1)

  -- One draw tick: each placement poses and draws once; per-instance rows
  -- accumulate into the per-scene totals.
  runtime:syncAnimatedDraws()
  Assert.equal(perf:count(a, "pose"), 1)
  Assert.equal(perf:count(b, "pose"), 1)
  Assert.equal(perf:count(a, "material"), 1, "drawItems evaluates materials")
  Assert.equal(perf:count(nil, "sync"), 1)
  Assert.isTrue(perf:seconds(nil, "sync") >= 0)
  Assert.equal(alloc:lastTick("pose"), 2, "one pose state per placement")
  Assert.equal(alloc:lastTick("items"), 2, "one draw item per placement mesh")
  Assert.equal(alloc:count("pose"), 2)

  -- A second tick accumulates totals and rolls the last-tick view.
  runtime:syncAnimatedDraws()
  Assert.equal(perf:count(a, "pose"), 2)
  Assert.equal(perf:count(nil, "sync"), 2)
  Assert.equal(alloc:lastTick("pose"), 2)
  Assert.equal(alloc:count("pose"), 4)

  -- The update pass counts advances in the same tick as the draw refresh.
  runtime:updateAnimated()
  Assert.equal(perf:count(a, "update"), 1)
  Assert.equal(alloc:lastTick("update"), 2)
  Assert.equal(alloc:lastTick("pose"), 2)
  Assert.equal(perf:count(nil, "sync"), 3)

  -- The summary renders the per-instance rows through a name mapping: both
  -- placements report pose, material, and update (sync stays scene-level).
  local rows = perf:summary(function(key)
    if type(key) == "table" then
      return key.definition.key .. "#" .. tostring(key.placementIndex)
    end
    return tostring(key)
  end)
  local names = {}
  for _, row in ipairs(rows) do
    names[#names + 1] = row.key .. "/" .. row.phase
  end
  table.sort(names)
  Assert.equal(#names, 6)
  Assert.equal(names[1], "outdoor:26:door#0/material")
  Assert.equal(names[2], "outdoor:26:door#0/pose")
  Assert.equal(names[3], "outdoor:26:door#0/update")
  Assert.equal(names[4], "outdoor:26:door#1/material")

  runtime:release()
end

function T.band_swaps_are_counted_per_swapped_instance()
  local desc = skyDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "indoor:113:sky",
      transform = identityMatrix(),
    },
    {
      placementIndex = 1,
      modelKey = "indoor:113:sky",
      transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 0, 0, 1 },
    },
  }, { [desc.key] = desc })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local perf = runtime.perf
  local a, b = runtime.animatedInstances[1], runtime.animatedInstances[2]
  runtime:setTimeBand("nite")
  Assert.equal(perf:count(a, "bandSwap"), 1)
  Assert.equal(perf:count(b, "bandSwap"), 1)
  runtime:setTimeBand("eve")
  Assert.equal(perf:count(a, "bandSwap"), 2)
  Assert.equal(perf:count(b, "bandSwap"), 2)
  Assert.equal(perf:count(nil, "sync"), 2, "each swap refreshes the draws")
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

-- Digest-side dynamic batches carry no skin attributes (rigid Nitro
-- geometry); strip them here to exercise the loader's stamp-and-encode.
local function stripSkinAttributes(desc)
  for _, mesh in ipairs(desc.dynamic.batches) do
    for _, v in ipairs(mesh.batch.vertices) do
      v.joints = nil
      v.weights = nil
    end
  end
  return desc
end

function T.rigid_nitro_batches_without_skin_attributes_load()
  local desc = stripSkinAttributes(doorDescriptor())
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local decodedMeshes = {}
  local runtime = MapSceneLoader.load(cache, assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")), {
    meshBuilder = function(decoded)
      decodedMeshes[#decodedMeshes + 1] = decoded
      return fakeMeshBuilder(decoded)
    end,
  })
  Assert.equal(runtime.stats.animatedInstances, 1)
  Assert.isTrue(#decodedMeshes >= 1, "the dynamic batches encoded as G4M3")
  for _, decoded in ipairs(decodedMeshes) do
    assert(decoded.joints and decoded.weights, "the G4M3 decode carries skin arrays")
    for i = 1, #decoded.vertices do
      Assert.deepEqual(decoded.joints[i], { 0, 0, 0, 0 }, "rigid vertex carries zero joint indices")
      Assert.deepEqual(decoded.weights[i], { 0, 0, 0, 0 }, "rigid vertex carries zero weights")
    end
  end
  runtime:release()
end

return T
