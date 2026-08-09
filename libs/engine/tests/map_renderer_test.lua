-- LÖVE smoke tests for the DS lighting shader and render pipeline. These run
-- under love (the test runner is launched with `love . --test`) because they
-- need a graphics context. If no graphics context is available the tests skip
-- themselves so the suite still passes in headless CI.

local Assert = require("tests.support.Assert")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local VertexFormat = require("libs.assets.src.VertexFormat")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

local function hasGraphics()
  return love and love.graphics and love.graphics.newShader
end

function T.shader_compiles()
  if not hasGraphics() then
    return
  end
  local r = MapRenderer.new()
  Assert.notNil(r.shader)
  r:release()
end

function T.shader_has_required_lighting_uniforms()
  if not hasGraphics() then
    return
  end
  local r = MapRenderer.new()
  local s = r.shader
  -- Presence is checked by sending a value; LÖVE errors for unknown names.
  s:send("u_lightEnabled0", true)
  s:send("u_lightVector0", { 0, 0, -1 })
  s:send("u_lightColor0", { 1, 1, 1 })
  s:send("u_diffuseColor", { 1, 1, 1 })
  s:send("u_ambientColor", { 0, 0, 0 })
  s:send("u_specularColor", { 0, 0, 0 })
  s:send("u_emissionColor", { 0, 0, 0 })
  r:release()
end

function T.shader_has_normal_matrix_uniform()
  if not hasGraphics() then
    return
  end
  local r = MapRenderer.new()
  -- Send as a 3x3 column-major matrix (nine values).
  r.shader:send("u_normalMatrix", "column", { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  r:release()
end

function T.field_edge_radius_uses_only_viewport_height()
  Assert.equal(MapRenderer.fieldEdgeRadiusPixels(192), 1)
  Assert.equal(MapRenderer.fieldEdgeRadiusPixels(384), 2)
  Assert.equal(MapRenderer.fieldEdgeRadiusPixels(1080), 6)
end

function T.field_viewport_sizes_and_rebuilds_render_targets()
  if not hasGraphics() then
    return
  end
  local renderer = MapRenderer.new()
  -- Spell the identity explicitly to keep this smoke independent of Matrix4.
  local identity = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1 }
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
  local runtime = {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
  }
  local viewport = FieldViewport.new(1280, 720, { mode = "strict" })
  renderer:draw(runtime, camera, nil, viewport)
  Assert.equal(renderer.canvasW, 960)
  Assert.equal(renderer.canvasH, 720)

  viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  for _ = 1, 10 do
    for _, size in ipairs({ { 960, 720 }, { 1280, 720 }, { 1680, 720 }, { 2560, 720 } }) do
      viewport:resize(size[1], size[2])
      renderer:draw(runtime, camera, nil, viewport)
    end
  end
  viewport:resize(1280, 720)
  renderer:draw(runtime, camera, nil, viewport)
  Assert.equal(renderer.canvasW, 1280)
  Assert.equal(renderer.canvasH, 720)
  renderer:release()
end

-- Build a tiny mesh with the project's vertex layout so the shader can be
-- exercised end-to-end without touching any compiled scene.
local function syntheticMesh(vertices)
  local indices = {}
  for i = 0, #vertices - 1 do
    indices[i + 1] = i
  end
  return love.graphics.newMesh(VertexFormat.LAYOUT, vertices, "triangles", "static")
end

-- An actor draw is a cutout billboard submitted as an overlay item, and it sets
-- per-item cull, depth, and alpha state. Nothing it touches may survive the
-- frame, or the 2D dialogue UI and the next map's draws inherit it.
function T.an_actor_billboard_draw_leaks_no_render_state()
  if not hasGraphics() then
    return
  end
  local lg = love.graphics
  local identity = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  local renderer = MapRenderer.new()
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
  local runtime = {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
  }
  local mesh = syntheticMesh({
    { -1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 2, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1 },
  })
  local actor = {
    mesh = mesh,
    material = { alphaClass = "cutout" },
    transform = identity,
    billboardBase = identity,
    alphaClass = "cutout",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 1,
    center = { 0, 1, 0 },
    submissionIndex = 1,
  }

  lg.setMeshCullMode("none")
  lg.setBlendMode("alpha")
  lg.setColor(1, 1, 1, 1)
  renderer:draw(runtime, camera, { actor }, FieldViewport.new(640, 480, { mode = "strict" }))

  Assert.isNil(lg.getCanvas(), "the scene canvas is unbound")
  Assert.isNil(lg.getShader(), "the map and edge shaders are unbound")
  Assert.equal(lg.getMeshCullMode(), "none")
  Assert.equal(lg.getBlendMode(), "alpha")
  Assert.isFalse(lg.isWireframe())
  local compare, depthWrite = lg.getDepthMode()
  Assert.equal(compare, "always", "depth testing is left disabled")
  Assert.isFalse(depthWrite)
  mesh:release()
  renderer:release()
end

function T.rejects_stale_scene_schema()
  local ok, err = pcall(MapSceneLoader.load, nil, { schema = "g4-map-scene-v1" })
  Assert.isTrue(
    not ok and err.code == "MAP_SCENE_UNSUPPORTED_SCHEMA",
    "rejects old scene schema: " .. tostring(err.code)
  )
end

function T.literal_color_triangle_ignores_light_direction()
  if not hasGraphics() then
    return
  end
  local r = MapRenderer.new()
  local s = r.shader
  s:send("u_proj", "column", {
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  })
  s:send("u_view", "column", {
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  })
  s:send("u_model", "column", {
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  })
  s:send("u_normalMatrix", "column", { 1, 0, 0, 0, 1, 0, 0, 0, 1 })

  -- Two different light directions that would change a lit vertex, but should
  -- not affect a literal-color vertex.
  for _, vec in ipairs({ { 0, 0, -1 }, { 0, 0, 1 } }) do
    s:send("u_lightEnabled0", true)
    s:send("u_lightVector0", vec)
    s:send("u_lightColor0", { 1, 0, 0 })
    s:send("u_diffuseColor", { 1, 1, 1 })
    s:send("u_ambientColor", { 0, 0, 0 })
    s:send("u_specularColor", { 0, 0, 0 })
    s:send("u_emissionColor", { 0, 0, 0 })

    local mesh = syntheticMesh({
      { 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
      { 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
      { 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    })
    s:send("u_useTexture", false)
    s:send("u_alphaMode", 0)
    s:send("u_alphaCutoff", 0.5 / 255)
    s:send("u_polygonAlpha", 1.0)
    s:send("u_polygonMode", 0)
    love.graphics.setShader(s)
    love.graphics.draw(mesh)
    love.graphics.setShader()
    mesh:release()
  end
  r:release()
end

return T
