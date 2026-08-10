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
  local LuaWriter = require("libs.rom.src.LuaWriter")
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

return T
