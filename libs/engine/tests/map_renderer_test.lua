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

function T.shader_has_polygon_light_mask_uniform()
  if not hasGraphics() then
    return
  end
  local r = MapRenderer.new()
  -- Presence is checked by sending a value; LÖVE errors for unknown names.
  r.shader:send("u_lightMask", { 1, 0, 0, 0 })
  r.shader:send("u_lightMask", { 0, 1, 0, 1 })
  r:release()
end

-- The compact per-draw uniform: one vec4 of 0/1 floats, bit i = light i of the
-- polygon's 4-bit mask. Different masks must decode to different uniforms and
-- mask 0 to all-off.
function T.light_mask_uniforms_decode_polygon_bits()
  Assert.deepEqual(MapRenderer.lightMaskUniforms(0), { 0, 0, 0, 0 })
  Assert.deepEqual(MapRenderer.lightMaskUniforms(1), { 1, 0, 0, 0 })
  Assert.deepEqual(MapRenderer.lightMaskUniforms(2), { 0, 1, 0, 0 })
  Assert.deepEqual(MapRenderer.lightMaskUniforms(5), { 1, 0, 1, 0 })
  Assert.deepEqual(MapRenderer.lightMaskUniforms(15), { 1, 1, 1, 1 })
  Assert.deepEqual(MapRenderer.lightMaskUniforms(), { 0, 0, 0, 0 })
  -- Masks outside the 4-bit polygon field are malformed data.
  Assert.throws(function()
    MapRenderer.lightMaskUniforms(16)
  end)
  Assert.throws(function()
    MapRenderer.lightMaskUniforms(-1)
  end)
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

-- An empty scene and camera for the state-restoration contract tests: the
-- renderer draws nothing but still binds/unbinds canvases, shaders, and state.
local function emptySceneCamera()
  local identity = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  return {
    camera = {
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
    },
    runtime = {
      mapDraws = {},
      buildingDraws = {},
      stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    },
  }
end

-- Injected graphics for the headless restoration-contract tests: a full
-- settable state surface (canvas, shader, blend, depth, wireframe, cull,
-- color) that the renderer must restore exactly, stub shaders/canvases for
-- construction, and a draw call that can fail on the Nth invocation so the
-- error path runs without a GL context.
local function fakeGraphics(opts)
  opts = opts or {}
  local shaders, canvases = {}, {}
  local drawCalls = 0
  local state = {
    canvas = opts.canvas,
    shader = opts.shader,
    blendMode = opts.blendMode,
    blendAlpha = opts.blendAlpha,
    depthMode = opts.depthMode,
    depthWrite = opts.depthWrite,
    wireframe = opts.wireframe,
    cullMode = opts.cullMode,
    color = opts.color or { 1, 1, 1, 1 },
  }
  return {
    shaders = shaders,
    canvases = canvases,
    newShader = function()
      local shader = {}
      shader.released = false
      shader.send = function() end
      shader.release = function()
        shader.released = true
      end
      shaders[#shaders + 1] = shader
      return shader
    end,
    newCanvas = function()
      local canvas = {}
      canvas.released = false
      canvas.setFilter = function() end
      canvas.release = function()
        canvas.released = true
      end
      canvases[#canvases + 1] = canvas
      return canvas
    end,
    getCanvas = function()
      return state.canvas
    end,
    setCanvas = function(canvas)
      state.canvas = canvas
    end,
    getShader = function()
      return state.shader
    end,
    setShader = function(shader)
      state.shader = shader
    end,
    getBlendMode = function()
      return state.blendMode, state.blendAlpha
    end,
    setBlendMode = function(mode, alpha)
      state.blendMode, state.blendAlpha = mode, alpha
    end,
    getDepthMode = function()
      return state.depthMode, state.depthWrite
    end,
    setDepthMode = function(mode, write)
      state.depthMode, state.depthWrite = mode, write
    end,
    isWireframe = function()
      return state.wireframe
    end,
    setWireframe = function(wireframe)
      state.wireframe = wireframe
    end,
    getMeshCullMode = function()
      return state.cullMode
    end,
    setMeshCullMode = function(mode)
      state.cullMode = mode
    end,
    getColor = function()
      return state.color[1], state.color[2], state.color[3], state.color[4]
    end,
    setColor = function(r, g, b, a)
      state.color = { r, g, b, a }
    end,
    draw = function()
      drawCalls = drawCalls + 1
      if opts.failOnDrawCall == drawCalls then
        error("injected draw failure")
      end
    end,
    clear = function() end,
  }
end

-- The exact restoration contract: every captured state (canvas, shader,
-- blend, depth, wireframe, cull, color) equals the pre-draw value, never a
-- hard-coded default. Colors round-trip through float32 on some GL drivers,
-- so they are compared within a small tolerance.
local function assertRestoredState(lg, canvas, shader)
  Assert.equal(lg.getCanvas(), canvas)
  Assert.equal(lg.getShader(), shader)
  local blend, alpha = lg.getBlendMode()
  Assert.equal(blend, "add")
  Assert.equal(alpha, "alphamultiply")
  local depthMode, depthWrite = lg.getDepthMode()
  Assert.equal(depthMode, "lequal")
  Assert.equal(depthWrite, true)
  Assert.equal(lg.isWireframe(), true)
  Assert.equal(lg.getMeshCullMode(), "back")
  local r, g, b, a = lg.getColor()
  Assert.near(r, 0.2, 1e-6)
  Assert.near(g, 0.4, 1e-6)
  Assert.near(b, 0.6, 1e-6)
  Assert.near(a, 0.8, 1e-6)
end

-- The renderer owns everything it created through the injected graphics: every
-- shader and canvas it built must be released when the renderer is released.
local function assertResourcesReleased(lg)
  for _, shader in ipairs(lg.shaders) do
    Assert.isTrue(shader.released, "renderer released every created shader")
  end
  for _, canvas in ipairs(lg.canvases) do
    Assert.isTrue(canvas.released, "renderer released every created canvas")
  end
  Assert.equal(#lg.shaders, 2, "the two engine shaders were created")
  Assert.equal(#lg.canvases, 3, "the scene, id-depth, and depth canvases were created")
end

function T.draw_restores_exact_caller_state()
  local canvas, shader = {}, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = true,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
  })
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  assertRestoredState(lg, canvas, shader)
  renderer:release()
  assertResourcesReleased(lg)
end

-- A draw failure must not leak the scene's state either: the captured caller
-- state is restored exactly and the original draw error is rethrown.
function T.draw_failure_restores_exact_state_and_rethrows()
  local canvas, shader = {}, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = true,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
    failOnDrawCall = 1,
  })
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local err = Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  assertRestoredState(lg, canvas, shader)
  renderer:release()
  assertResourcesReleased(lg)
end

-- An actor draw is a cutout billboard submitted as an overlay item, and it
-- sets per-item cull, depth, and alpha state. With non-default caller state
-- (a bound canvas, an active shader, add blending, depth testing, wireframe,
-- back-face culling, a tinted color) every modified state must come back to
-- the exact captured value, and the scissor the renderer never touches must be
-- left alone -- or the 2D dialogue UI and the next map's draws inherit it.
function T.draw_restores_exact_caller_state_on_real_graphics()
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

  local canvas = lg.newCanvas(64, 64)
  local shader = renderer.edgeShader
  lg.setCanvas(canvas)
  lg.setShader(shader)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  renderer:draw(runtime, camera, { actor }, FieldViewport.new(640, 480, { mode = "strict" }))

  assertRestoredState(lg, canvas, shader)
  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, 4, "scissor x is untouched")
  Assert.equal(sy, 8, "scissor y is untouched")
  Assert.equal(sw, 32, "scissor width is untouched")
  Assert.equal(sh, 16, "scissor height is untouched")

  -- Restoration re-bound the exact pre-draw state (including this test's
  -- deliberately non-default blend/depth/wireframe/cull/color); reset it to
  -- the LÖVE defaults so the tests that follow start from a clean baseline.
  lg.setCanvas()
  lg.setShader()
  lg.setScissor()
  lg.setBlendMode("alpha")
  lg.setDepthMode()
  lg.setWireframe(false)
  lg.setMeshCullMode("none")
  lg.setColor(1, 1, 1, 1)
  mesh:release()
  renderer:release()
end

-- End-to-end mask behavior: the same triangle, material, and profile render
-- different colors under different polygon light masks. Reads the scene canvas
-- back after each masked draw; the lit mask draws the head-on white light,
-- the zero mask renders emission-only (black).
function T.polygon_light_mask_changes_the_rendered_result()
  if not hasGraphics() then
    return
  end
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
  local white = 31 + 31 * 32 + 31 * 1024
  local runtime = {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    lighting = {
      records = {
        {
          startHalfSeconds = 0,
          lights = {
            { enabled = true, colorRgb555 = white, vectorFx12 = { 0, 0, -4096 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          },
          diffuseRgb555 = white,
          ambientRgb555 = 0,
          specularRgb555 = 0,
          emissionRgb555 = 0,
        },
      },
    },
  }
  -- A lit vertex (color source 3) with a +Z normal, so the head-on light
  -- contributes full diffuse. With the identity camera the triangle covers the
  -- lower-right half of the viewport (the shader flips clip Y).
  local mesh = syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  })
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local function sample(mask)
    renderer:draw(runtime, camera, {
      {
        mesh = mesh,
        material = { alphaClass = "opaque" },
        transform = identity,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = mask,
        center = { 0.5, 0.5, 0 },
        submissionIndex = 1,
      },
    }, viewport)
    local img = renderer.sceneColor:newImageData()
    return img:getPixel(416, 384) -- NDC (0.3, -0.6): well inside the triangle
  end
  local lit = { sample(1) }
  local unlit = { sample(0) }
  Assert.near(lit[1], 255, 2)
  Assert.near(lit[2], 255, 2)
  Assert.near(lit[3], 255, 2)
  Assert.near(unlit[1], 0, 2)
  Assert.near(unlit[2], 0, 2)
  Assert.near(unlit[3], 0, 2)
  mesh:release()
  renderer:release()
end

-- A runtime with no lighting profile must not inherit the previous lit
-- scene's light/material uniforms: the profile-less draw explicitly sends
-- disabled lights and zero material colors, so a NORMAL-lit vertex and a
-- field-diffuse vertex both render dark after a bright lit frame instead of
-- the lit frame's values. Canvas readbacks come back Y-inverted on some GL
-- drivers, so each triangle is sampled at both its canonical position and its
-- mirrored position; exactly one of the two is interior in any environment.
-- The readback scale is likewise driver-dependent (0..255 or 0..1), so the
-- brightness threshold is derived from an actual sample.
function T.lit_then_unlit_scene_does_not_inherit_lighting()
  if not hasGraphics() then
    return
  end
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
  local white = 31 + 31 * 32 + 31 * 1024
  local litRuntime = {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    lighting = {
      records = {
        {
          startHalfSeconds = 0,
          lights = {
            { enabled = true, colorRgb555 = white, vectorFx12 = { 0, 0, -4096 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          },
          diffuseRgb555 = white,
          ambientRgb555 = white,
          specularRgb555 = 0,
          emissionRgb555 = white,
        },
      },
    },
  }
  local unlitRuntime = {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
  }
  -- Triangle 1 (right half) uses a NORMAL color source, so it is shaded by
  -- the light and material uniforms; triangle 2 (left half) uses the
  -- field-diffuse source and reads u_diffuseColor directly.
  local mesh = syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2 },
    { -1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2 },
    { 0, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2 },
  })
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local item = {
    mesh = mesh,
    material = { alphaClass = "opaque" },
    transform = identity,
    alphaClass = "opaque",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 15,
    center = { 0.5, 0.5, 0 },
    submissionIndex = 1,
  }
  -- Interior points of the two triangles plus their Y-mirrored counterparts
  -- (the 640x480 canvas mirrors to a 480 pixel row 95/383).
  local normalSamples = { { 416, 384 }, { 416, 95 } }
  local diffuseSamples = { { 224, 96 }, { 224, 383 } }

  local function isBright(img, x, y, threshold)
    local r, g, b = img:getPixel(x, y)
    return r >= threshold and g >= threshold and b >= threshold
  end

  local function anyBright(img, samples, threshold)
    for _, p in ipairs(samples) do
      if isBright(img, p[1], p[2], threshold) then
        return true
      end
    end
    return false
  end

  -- The lit frame is bright at both triangles: the NORMAL triangle under a
  -- head-on light, the field-diffuse triangle from the white diffuse color.
  renderer:draw(litRuntime, camera, { item }, viewport)
  local litImg = renderer.sceneColor:newImageData()
  local sr, sg, sb = litImg:getPixel(0, 0)
  local threshold = (sr > 1 or sg > 1 or sb > 1) and 127 or 0.5
  Assert.isTrue(anyBright(litImg, normalSamples, threshold), "lit frame shades the NORMAL triangle")
  Assert.isTrue(anyBright(litImg, diffuseSamples, threshold), "lit frame shades the field-diffuse triangle")

  -- The profile-less frame must reset every lighting/material uniform: neither
  -- triangle may stay bright from the lit frame's light or diffuse values.
  renderer:draw(unlitRuntime, camera, { item }, viewport)
  local unlitImg = renderer.sceneColor:newImageData()
  Assert.isFalse(anyBright(unlitImg, normalSamples, threshold), "unlit frame inherits the previous light state")
  Assert.isFalse(anyBright(unlitImg, diffuseSamples, threshold), "unlit frame inherits the previous material color")

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
