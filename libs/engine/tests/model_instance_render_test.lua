-- LÖVE smoke tests for the non-Nitro proof fixture: a ModelInstance built
-- from generic IR geometry renders through the production MapRenderer. These
-- run under love and skip themselves when no graphics context is available,
-- like the other renderer smoke tests.

local Assert = require("tests.support.Assert")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MeshWriter = require("libs.assets.src.MeshWriter")
local SceneMesh = require("libs.engine.src.SceneMesh")
local FieldViewport = require("libs.engine.src.FieldViewport")
local ModelInstance = require("libs.engine.src.ModelInstance")
local GenericModelFixture = require("tests.support.GenericModelFixture")

local T = {}

local function hasGraphics()
  return love and love.graphics and love.graphics.newShader
end

-- Build love meshes for every definition batch through the production mesh
-- path (G4M3 encode -> decode -> build).
local function buildRenders(def)
  local renders = {}
  for _, mesh in ipairs(def.meshes) do
    local bytes = MeshWriter.encode(mesh.batch, { format = "g4m3" })
    renders[mesh.id] = SceneMesh.build(SceneMesh.decode(bytes))
  end
  return renders
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

local function drawInstance(renderer, runtime, instance, alpha)
  local items = instance:drawItems(instance.renders)
  runtime.mapDraws = items
  renderer:draw(runtime, identityCamera(), nil, FieldViewport.new(320, 240, { mode = "strict" }), alpha)
end

function T.generic_animated_fixture_renders_through_map_renderer()
  if not hasGraphics() then
    return
  end
  local lg = love.graphics
  local renderer = MapRenderer.new()
  local def = GenericModelFixture.doorDefinition()
  local instance = ModelInstance.new(def)
  instance.renders = buildRenders(def)
  local runtime = {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    lighting = nil,
  }

  instance:play("door.open")
  instance:updateFixed()
  instance:evaluatePose()
  drawInstance(renderer, runtime, instance, 1)
  local firstDrawCalls = renderer.stats.drawCalls
  Assert.isTrue(firstDrawCalls >= 3, "all three fixture meshes draw")

  -- Scrubbing to another frame reuses the same built meshes (no geometry
  -- recompilation per frame) and still draws.
  instance:updateFixed()
  instance:updateFixed()
  instance:evaluatePose()
  local rendersBefore = instance.renders
  drawInstance(renderer, runtime, instance, 1)
  Assert.isTrue(renderer.stats.drawCalls >= 3)
  Assert.equal(instance.renders, rendersBefore, "meshes are built once, not per frame")

  -- No render state leaks into the next frame.
  Assert.isNil(lg.getCanvas(), "the scene canvas is unbound")
  Assert.isNil(lg.getShader(), "the map and edge shaders are unbound")
  Assert.equal(lg.getMeshCullMode(), "none")
  Assert.isFalse(lg.isWireframe())

  for _, mesh in pairs(instance.renders) do
    mesh:release()
  end
  renderer:release()
end

function T.hidden_node_geometry_is_not_drawn()
  if not hasGraphics() then
    return
  end
  local renderer = MapRenderer.new()
  local def = GenericModelFixture.doorDefinition()
  local instance = ModelInstance.new(def)
  instance.renders = buildRenders(def)
  local runtime = {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    lighting = nil,
  }

  instance:play("blink")
  instance:updateFixed()
  instance:updateFixed() -- frame 2: leaf hidden
  instance:evaluatePose()
  drawInstance(renderer, runtime, instance, 1)
  Assert.equal(renderer.stats.drawCalls, 2, "the hidden leaf mesh is not drawn")

  for _, mesh in pairs(instance.renders) do
    mesh:release()
  end
  renderer:release()
end

return T
