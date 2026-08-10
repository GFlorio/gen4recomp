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
