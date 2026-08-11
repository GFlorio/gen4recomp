-- Renderer smoke tests for the nitro-backed ModelInstance: the door fixture
-- renders through the production MapRenderer and scrubbing frames reuses the
-- built meshes. The suite builds real GPU resources, so it declares the
-- graphics layer and the runner skips it explicitly on hosts without one.

local Assert = require("tests.support.Assert")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MeshWriter = require("libs.assets.src.MeshWriter")
local SceneMesh = require("libs.engine.src.SceneMesh")
local FieldViewport = require("libs.engine.src.FieldViewport")
local ModelInstance = require("libs.engine.src.ModelInstance")
local NitroModelFixture = require("tests.support.NitroModelFixture")

local T = {}

-- Build love meshes for every definition mesh through the production mesh
-- path (G4M2 encode -> decode -> build), keyed by mesh id like the loader's
-- renderMeshesById. The fixture mesh references the .g4mesh path shape; the
-- bytes come from the shared door quad.
local function buildRenders(def)
  local renderMeshesById = {}
  for _, mesh in ipairs(def.meshes) do
    local bytes = MeshWriter.encode(NitroModelFixture.doorQuad())
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
    billboardProjection = function()
      return identity
    end,
  }
end

local function drawInstance(renderer, runtime, instance, alpha)
  local items = instance:drawItems(instance.renderMeshesById)
  runtime.mapDraws = items
  for index, item in ipairs(items) do
    item.submissionIndex = index
  end
  renderer:draw(runtime, identityCamera(), items, FieldViewport.new(320, 240, { mode = "strict" }), alpha)
end

function T.nitro_animated_fixture_renders_through_map_renderer()
  local lg = love.graphics
  local renderer = MapRenderer.new()
  local def = NitroModelFixture.doorDefinition()
  local instance = ModelInstance.new(def)
  instance.renderMeshesById = buildRenders(def)
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
  Assert.isTrue(firstDrawCalls >= 1, "the door mesh draws")

  -- Scrubbing to another frame reuses the same built meshes (no geometry
  -- recompilation per frame) and still draws.
  instance:updateFixed()
  instance:updateFixed()
  instance:evaluatePose()
  local rendersBefore = instance.renderMeshesById
  drawInstance(renderer, runtime, instance, 1)
  Assert.isTrue(renderer.stats.drawCalls >= 1)
  Assert.equal(instance.renderMeshesById, rendersBefore, "meshes are built once, not per frame")

  -- No render state leaks into the next frame.
  Assert.isNil(lg.getCanvas(), "the scene canvas is unbound")
  Assert.isNil(lg.getShader(), "the map and edge shaders are unbound")
  Assert.equal(lg.getMeshCullMode(), "none")
  Assert.isFalse(lg.isWireframe())

  for _, mesh in pairs(instance.renderMeshesById) do
    mesh:release()
  end
  renderer:release()
end

return {
  metadata = { layer = "graphics", capabilities = { "graphics" } },
  tests = T,
}
