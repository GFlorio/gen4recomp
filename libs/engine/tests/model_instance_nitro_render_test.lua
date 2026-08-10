-- LÖVE smoke tests for the Nitro dynamic path: a nitro-backed ModelInstance
-- (compiled transform program + compiled clip) renders through the
-- production MapRenderer, scrubs frames without recompiling geometry, and
-- follows the same item contract as the generic fixture. These run under
-- love and skip themselves when no graphics context is available, like the
-- other renderer smoke tests.

local Assert = require("tests.support.Assert")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MeshWriter = require("libs.assets.src.MeshWriter")
local SceneMesh = require("libs.engine.src.SceneMesh")
local FieldViewport = require("libs.engine.src.FieldViewport")
local ModelInstance = require("libs.engine.src.ModelInstance")
local ModelDefinition = require("libs.engine.src.ModelDefinition")

local T = {}

local function hasGraphics()
  return love and love.graphics and love.graphics.newShader
end

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

-- A compiled rotation clip over 8 frames (pivot A = 1 - i/16, B = i/16,
-- like the real `door_op`).
local function doorClip()
  local rotData = {}
  for i = 0, 7 do
    rotData[i + 1] = { control = 0x0024, a = 4096 - i * 256, b = i * 256 }
  end
  local keys = {}
  for i = 0, 7 do
    keys[i + 1] = 0x8000 + i
  end
  return {
    id = "fixture:nitro-door",
    name = "door_op",
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { "door.open" },
    source = { type = "nitro", format = "NSBCA", archive = "a106", memberId = 1 },
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

-- A one-door nitro model: a single node, one SBC draw, one segment mesh
-- (a 2x2-tile quad at the origin in tile space).
local function doorDefinition()
  local program = {
    name = "door",
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
  local quad = {
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
  }
  return ModelDefinition.new({
    key = "fixture:nitro-door",
    sourceBackend = "nitro",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = { { id = "draw0.seg0", nodeIndex = 0, materialIndex = 0, batch = quad } },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
      },
    },
    skins = {},
    animations = { doorClip() },
    backend = {
      program = program,
      meshes = { ["draw0.seg0"] = { drawIndex = 0, positionSource = "draw", transformMode = "static" } },
    },
  })
end

local function buildRenders(def)
  local renderMeshesById = {}
  for _, mesh in ipairs(def.meshes) do
    local bytes = MeshWriter.encode(mesh.batch)
    renderMeshesById[mesh.id] = SceneMesh.build(SceneMesh.decode(bytes))
  end
  return renderMeshesById
end

local function identityCamera()
  local identity = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  return {
    distance = 26,
    view = function()
      return identity
    end,
    projection = function()
      return identity
    end,
  }
end

local function runtime()
  return {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    lighting = nil,
  }
end

local function drawInstance(renderer, rt, instance, alpha)
  local items = instance:drawItems(instance.renderMeshesById)
  rt.mapDraws = items
  renderer:draw(rt, identityCamera(), nil, FieldViewport.new(320, 240, { mode = "strict" }), alpha)
  return items
end

function T.nitro_animated_model_renders_and_scrubs_without_recompiling()
  if not hasGraphics() then
    return
  end
  local renderer = MapRenderer.new()
  local def = doorDefinition()
  local instance = ModelInstance.new(def)
  instance.renderMeshesById = buildRenders(def)
  local rt = runtime()

  -- Bind pose first: the draw matrix is identity, so the quad renders at
  -- its tile-space placement.
  instance:evaluatePose()
  drawInstance(renderer, rt, instance, 1)
  Assert.isTrue(renderer.stats.drawCalls >= 1, "the nitro mesh draws")

  -- Scrub through several frames; the same built meshes serve every frame.
  local rendersBefore = instance.renderMeshesById
  instance:play("door.open")
  for _ = 1, 7 do
    instance:updateFixed()
    instance:evaluatePose()
    local items = drawInstance(renderer, rt, instance, 1)
    Assert.equal(#items, 1, "one mesh per frame")
  end
  Assert.equal(instance.renderMeshesById, rendersBefore, "meshes are built once, not per frame")
  -- The final frame's rotation cells differ from the bind pose.
  Assert.isTrue(
    math.abs(instance.poseState.drawMatrices["draw0.seg0"].position[1] - 1) > 0.01,
    "scrubbed rotation reached the pose"
  )

  Assert.isNil(love.graphics.getCanvas(), "the scene canvas is unbound")
  Assert.isNil(love.graphics.getShader(), "the map and edge shaders are unbound")
  for _, mesh in pairs(instance.renderMeshesById) do
    mesh:release()
  end
  renderer:release()
end

return T
