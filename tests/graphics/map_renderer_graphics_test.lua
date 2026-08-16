-- Graphics smoke tests for the DS lighting shader and the render pipeline.
-- These need a real offscreen context: the shaders go through the GLSL
-- compiler, the render targets are real canvases, and the state assertions read
-- back what the driver actually holds. Nothing here is skippable in the
-- supported environments — a host without the graphics capability skips the
-- whole suite explicitly through the runner.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.MeshWriter")
local FakeCache = require("tests.support.FakeCache")
local VertexFormat = require("libs.assets.src.VertexFormat")
local FieldViewport = require("libs.engine.src.FieldViewport")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

-- Spelled explicitly to keep these smokes independent of Matrix4.
local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_NORMAL = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

local function fixedCamera()
  local function identity()
    return IDENTITY
  end
  return { distance = 26, far = 400, view = identity, projection = identity, billboardProjection = identity }
end

local function zeroFogFixture()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = 0
  end
  return { enabled = false, color = 0, offset = 0, table = table32 }
end

local function emptyRuntime()
  return {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = zeroFogFixture(),
  }
end

-- A tiny mesh in the project's vertex layout, so the shader can be exercised
-- end-to-end without touching any compiled scene.
local function syntheticMesh(vertices)
  return love.graphics.newMesh(VertexFormat.LAYOUT, vertices, "triangles", "static")
end

function T.shader_compiles(scope)
  local renderer = scope:own(MapRenderer.new())

  Assert.notNil(renderer.shader)
end

function T.shader_has_required_lighting_uniforms(scope)
  local shader = scope:own(MapRenderer.new()).shader

  -- Presence is checked by sending a value; LÖVE errors for unknown names.
  -- The u_mat* uniforms carry the effective DS material registers (the
  -- field profile, overridden by any playing NSBMA color clip).
  shader:send("u_lightEnabled0", true)
  shader:send("u_lightVector0", { 0, 0, -1 })
  shader:send("u_lightColor0", { 1, 1, 1 })
  shader:send("u_matDiffuse", { 1, 1, 1 })
  shader:send("u_matAmbient", { 0, 0, 0 })
  shader:send("u_matSpecular", { 0, 0, 0 })
  shader:send("u_matEmission", { 0, 0, 0 })
end

function T.shader_has_model_normal_uniform(scope)
  local renderer = scope:own(MapRenderer.new())

  -- Sent as a 3x3 column-major matrix (nine values).
  renderer.shader:send("u_modelNormal", "column", IDENTITY_NORMAL)
end

function T.shader_has_billboard_uniforms(scope)
  local shader = scope:own(MapRenderer.new()).shader

  shader:send("u_billboard", true)
  shader:send("u_billboardCenter", { 3, 4, 5 })
  shader:send("u_billboardScale", { 2, 3, 4 })
end

function T.shader_has_polygon_light_mask_uniform(scope)
  local shader = scope:own(MapRenderer.new()).shader

  -- Presence is checked by sending a value; LÖVE errors for unknown names.
  shader:send("u_lightMask", { 1, 0, 0, 0 })
  shader:send("u_lightMask", { 0, 1, 0, 1 })
end

-- The ROM census proves fogEnabled is exercised by most HGSS field
-- materials, so the fidelity shader carries a per-fragment fog gate, the
-- global fog color, and the 32-entry density table -- applied
-- post-composition (GBATEK "3D Display - Fog"), not invented distance fog
-- from camera near/far.
function T.shader_has_fog_uniforms(scope)
  local shader = scope:own(MapRenderer.new()).shader

  local zeroFogTable = {}
  for i = 1, 32 do
    zeroFogTable[i] = 0
  end

  shader:send("u_fogEnabled", true)
  shader:send("u_fogColor", { 0.5, 0.5, 0.5 })
  shader:send("u_fogTable", zeroFogTable)
  shader:send("u_fogOffset", 0)
end

-- The DS composites edge color by RGB replacement, not an alpha-mix
-- scalar, so the fidelity shader carries no alpha-mix uniform to blend
-- against. Absence is checked the same way presence is checked elsewhere in
-- this suite: LÖVE errors when a name is not a real uniform of the compiled
-- shader.
function T.edge_shader_has_no_alpha_mix_uniform(scope)
  local edgeShader = scope:own(MapRenderer.new()).edgeShader

  Assert.throws(function()
    edgeShader:send("u_edgeAlpha", 0.5)
  end)
end

function T.field_viewport_sizes_and_rebuilds_render_targets(scope)
  local renderer = scope:own(MapRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()

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
end

-- The 2x DS-relative world raster against real driver resources: the
-- renderer allocates its targets at the derived raster size rather than
-- the raw display viewport, several host resolutions at the same aspect and
-- scale reuse that same raster target instead of reallocating, and the
-- composited scene canvas is nearest-filtered on the real driver like idDepth
-- already is.
function T.raster_scale_derives_and_reuses_target_size_and_nearest_filters_scene_color(scope)
  local renderer = scope:own(MapRenderer.new({ rasterScale = 2 }))
  local camera, runtime = fixedCamera(), emptyRuntime()

  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  renderer:draw(runtime, camera, nil, viewport)
  Assert.equal(renderer.canvasW, 683)
  Assert.equal(renderer.canvasH, 384)
  local min, mag = renderer.sceneColor:getFilter()
  Assert.equal(min, "nearest", "the composited scene canvas is nearest-filtered")
  Assert.equal(mag, "nearest")

  local targets = renderer._sceneTargets
  for _, size in ipairs({ { 1920, 1080 }, { 2560, 1440 } }) do
    viewport:resize(size[1], size[2])
    renderer:draw(runtime, camera, nil, viewport)
    Assert.equal(renderer.canvasW, 683, "same aspect/scale reuses the 683x384 raster")
    Assert.equal(renderer.canvasH, 384)
    Assert.equal(renderer._sceneTargets, targets, "same derived raster size does not reallocate targets")
  end
end

-- An actor draw is a cutout billboard submitted as an overlay item, and it sets
-- per-item cull, depth, and alpha state. Nothing it touches may survive the
-- frame, or the 2D dialogue UI and the next map's draws inherit it.
function T.an_actor_billboard_draw_leaks_no_render_state(scope)
  local lg = love.graphics
  local renderer = scope:own(MapRenderer.new())
  local mesh = scope:own(syntheticMesh({
    { -1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 2, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1 },
  }))
  local actor = {
    mesh = mesh,
    material = { alphaClass = "cutout", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    billboardBase = IDENTITY,
    billboardCenter = { 0, 0, 0 },
    billboardScale = { 1, 1, 1 },
    alphaClass = "cutout",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 1,
    alphaCutoff = 0.5 / 255,
    center = { 0, 1, 0 },
  }

  lg.setMeshCullMode("none")
  lg.setBlendMode("alpha")
  lg.setColor(1, 1, 1, 1)
  renderer:draw(emptyRuntime(), fixedCamera(), { { actor } }, FieldViewport.new(640, 480, { mode = "strict" }))

  Assert.isNil(lg.getCanvas(), "the scene canvas is unbound")
  Assert.isNil(lg.getShader(), "the map and edge shaders are unbound")
  Assert.equal(lg.getMeshCullMode(), "none")
  Assert.equal(lg.getBlendMode(), "alpha")
  Assert.isFalse(lg.isWireframe())
  local compare, depthWrite = lg.getDepthMode()
  Assert.equal(compare, "always", "depth testing is left disabled")
  Assert.isFalse(depthWrite)
end

function T.literal_color_triangle_ignores_light_direction(scope)
  local shader = scope:own(MapRenderer.new()).shader

  shader:send("u_proj", "column", IDENTITY)
  shader:send("u_view", "column", IDENTITY)
  shader:send("u_model", "column", IDENTITY)
  shader:send("u_modelNormal", "column", IDENTITY_NORMAL)

  -- Two light directions that would change a lit vertex, but must not affect a
  -- literal-color one.
  for _, vector in ipairs({ { 0, 0, -1 }, { 0, 0, 1 } }) do
    shader:send("u_lightEnabled0", true)
    shader:send("u_lightVector0", vector)
    shader:send("u_lightColor0", { 1, 0, 0 })
    shader:send("u_matDiffuse", { 1, 1, 1 })
    shader:send("u_matAmbient", { 0, 0, 0 })
    shader:send("u_matSpecular", { 0, 0, 0 })
    shader:send("u_matEmission", { 0, 0, 0 })
    shader:send("u_useTexture", false)
    shader:send("u_alphaMode", 0)
    shader:send("u_alphaCutoff", 0.5 / 255)
    shader:send("u_polygonAlpha", 1.0)
    shader:send("u_polygonMode", 0)

    local mesh = scope:own(syntheticMesh({
      { 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
      { 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
      { 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    }))
    love.graphics.setShader(shader)
    love.graphics.draw(mesh)
    love.graphics.setShader()
  end
end

-- A 1x1 solid-color texture at the given alpha (0-255 scale, matching this
-- file's other synthetic PNG helpers).
local function solidAlphaImage(scope, r, g, b, alpha)
  local data = love.image.newImageData(1, 1)
  data:setPixel(0, 0, r / 255, g / 255, b / 255, alpha / 255)
  return scope:own(love.graphics.newImage(data))
end

-- A green literal-color triangle (colorSource 0) covering the same screen
-- area polygon_light_mask_changes_the_rendered_result samples: interior at
-- canvas (416, 384) or its Y-mirror (416, 95), whichever the driver's
-- readback lands on.
local function decalTriangle(scope)
  return scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { 1, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0 },
  }))
end

local function decalItem(mesh, image)
  return {
    mesh = mesh,
    material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, image = image },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "opaque",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "decal",
    polygonId = 0,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0.5, 0.5, 0 },
  }
end

-- The brighter of the two candidate interior samples (readbacks come back
-- Y-inverted on some GL drivers, so exactly one of (416,384)/(416,95) is
-- interior against the black clear color; the other reads pure background).
local function decalInteriorSample(renderer)
  local img = renderer.sceneColor:newImageData()
  local a, b = { img:getPixel(416, 384) }, { img:getPixel(416, 95) }
  local function sum(p)
    return p[1] + p[2] + p[3]
  end
  return sum(a) >= sum(b) and a or b
end

-- DS DECAL keeps the texture RGB only where the texel is fully opaque
-- (texture alpha 31/31); a fully transparent decal texel (alpha 0) must
-- render the vertex color untouched instead (GBATEK DECAL texel format).
function T.decal_zero_texture_alpha_renders_vertex_color(scope)
  local renderer = scope:own(MapRenderer.new())
  local image = solidAlphaImage(scope, 255, 0, 0, 0)
  local item = decalItem(decalTriangle(scope), image)

  renderer:draw(emptyRuntime(), fixedCamera(), { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))

  local p = decalInteriorSample(renderer)
  local scale = p[2] > 1 and 255 or 1
  Assert.isTrue(p[2] >= 0.5 * scale, "a fully transparent decal texel must render the vertex color's green channel")
  Assert.isTrue(p[1] < 0.5 * scale, "a fully transparent decal texel must not render the texture's red channel")
end

-- A partially transparent DECAL texel (texture alpha strictly between 0 and
-- 31/31) must interpolate texture and vertex RGB by that alpha, not render
-- the texture color unconditionally (GBATEK DECAL texel format).
function T.decal_partial_texture_alpha_blends_toward_vertex_color(scope)
  local renderer = scope:own(MapRenderer.new())
  local image = solidAlphaImage(scope, 255, 0, 0, 128)
  local item = decalItem(decalTriangle(scope), image)

  renderer:draw(emptyRuntime(), fixedCamera(), { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))

  local p = decalInteriorSample(renderer)
  local scale = p[2] > 1 and 255 or 1
  Assert.isTrue(p[2] >= 0.2 * scale, "a partially transparent decal texel must blend in the vertex color's green")
end

-- A literal-color vertex triangle (colorSource 0) for the MODULATE test
-- below: r/g/b are set per call so a nontrivial, non-identity vertex color
-- can be paired with a nontrivial texture color.
local function modulateTriangle(scope, r, g, b)
  return scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, r, g, b, 1, 0 },
    { 1, 0, 0, 1, 0, 0, 0, 1, r, g, b, 1, 0 },
    { 0, 1, 0, 0, 1, 0, 0, 1, r, g, b, 1, 0 },
  }))
end

-- MODULATE, the DS integer combiner (map.glsl's modulateRgb6/
-- modulateComponent6), at a nontrivial midrange value -- not an
-- identity/full-white or zero edge case. Both operands enter 5-bit
-- quantized then widened to 6-bit (expand5to6) before combining:
--   modulateComponent6(t6, v6) = floor(((t6+1)*(v6+1)-1)/64)
-- Texture (200,100,50)/255 -> texture5 = floor(c*31+0.5) = (24,12,6) ->
-- texture6 = expand5to6 = (49,24,12). A literal vertex color (colorSource 0)
-- (128,64,200)/255 is truncated, not rounded, by the vertex stage's
-- quantizeRgb5 (floor(c*31), no +0.5) -> vertex5 = (15,7,24) -> vertex6 =
-- (30,14,49). Per channel: R floor((50*31-1)/64)=24, G
-- floor((25*15-1)/64)=5, B floor((13*50-1)/64)=10.
function T.modulate_combines_texture_and_vertex_color_at_a_nontrivial_midrange_value(scope)
  local renderer = scope:own(MapRenderer.new())
  local image = solidAlphaImage(scope, 200, 100, 50, 255)
  local item = decalItem(modulateTriangle(scope, 128 / 255, 64 / 255, 200 / 255), image)
  item.polygonMode = "modulation"

  renderer:draw(emptyRuntime(), fixedCamera(), { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))

  local p = decalInteriorSample(renderer)
  local scale = p[1] > 1 and 255 or 1
  Assert.near(p[1], 24 / 63 * scale, 1, "modulate red channel: floor((50*31-1)/64) = 24")
  Assert.near(p[2], 5 / 63 * scale, 1, "modulate green channel: floor((25*15-1)/64) = 5")
  Assert.near(p[3], 10 / 63 * scale, 1, "modulate blue channel: floor((13*50-1)/64) = 10")
end

-- A cutout fragment whose combined alpha falls below alphaCutoff must
-- discard rather than write a below-threshold pixel: DS cutout draws
-- (grass, fences) render exactly two states, transparent or opaque, never a
-- partial blend (GBATEK POLYGON_ATTR alpha=0 -> transparent). A fully
-- transparent texel (textureAlpha5 = 0) makes the MODULATE alpha combiner
-- floor(((0+1)*(31+1)-1)/32) = 0, normalized alpha 0, below alphaCutoff --
-- the fragment must discard, leaving the injected clear color untouched
-- rather than blending toward it.
function T.cutout_zero_alpha_fragment_discards_instead_of_rendering(scope)
  local clearColor = { 0.1, 0.2, 0.3, 1 }
  local renderer = scope:own(MapRenderer.new({ clearColor = clearColor }))
  local image = solidAlphaImage(scope, 255, 0, 0, 0)
  local item = decalItem(decalTriangle(scope), image)
  item.polygonMode = "modulation"
  item.alphaClass = "cutout"

  renderer:draw(emptyRuntime(), fixedCamera(), { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))

  local p = decalInteriorSample(renderer)
  local scale = p[1] > 1 and 255 or 1
  Assert.near(p[1], clearColor[1] * scale, 0.05 * scale, "a discarded cutout fragment leaves the clear color's red")
  Assert.near(p[2], clearColor[2] * scale, 0.05 * scale, "a discarded cutout fragment leaves the clear color's green")
  Assert.near(p[3], clearColor[3] * scale, 0.05 * scale, "a discarded cutout fragment leaves the clear color's blue")
end

-- Exact caller-state restoration on a real driver: with non-default caller
-- state (a bound canvas, an active shader, add blending,
-- depth testing, wireframe, back-face culling, a tinted color) every modified
-- state must come back to the exact captured value -- the scene's cutout
-- actor and a wireframe item dirty cull mode and the wireframe state during
-- the draw -- and the scissor the renderer never touches must be left alone
-- -- or the 2D dialogue UI and the next map's draws inherit it. Colors
-- round-trip through float32 on some GL drivers, so they are compared within
-- a small tolerance.
function T.draw_restores_exact_caller_state_on_real_graphics(scope)
  local lg = love.graphics
  local renderer = scope:own(MapRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  local mesh = scope:own(syntheticMesh({
    { -1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 2, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1 },
  }))
  local actor = {
    mesh = mesh,
    material = { alphaClass = "cutout", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    billboardBase = IDENTITY,
    billboardCenter = { 0, 0, 0 },
    billboardScale = { 1, 1, 1 },
    alphaClass = "cutout",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 1,
    alphaCutoff = 0.5 / 255,
    center = { 0, 1, 0 },
  }
  local wireframeItem = {
    mesh = mesh,
    alphaClass = "wireframe",
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 1,
    alphaCutoff = 0.5 / 255,
    center = { 0, 1, 0 },
  }

  local canvas = scope:own(lg.newCanvas(64, 64))
  local shader = renderer.edgeShader
  lg.setCanvas(canvas)
  lg.setShader(shader)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  renderer:draw(runtime, camera, { { actor, wireframeItem } }, FieldViewport.new(640, 480, { mode = "strict" }))

  Assert.equal(lg.getCanvas(), canvas, "the pre-draw canvas is re-bound")
  Assert.equal(lg.getShader(), shader, "the pre-draw shader is re-bound")
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
  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, 4, "scissor x is untouched")
  Assert.equal(sy, 8, "scissor y is untouched")
  Assert.equal(sw, 32, "scissor width is untouched")
  Assert.equal(sh, 16, "scissor height is untouched")
end

-- End-to-end per-polygon light-mask behavior: the same triangle, material,
-- and profile render different colors under different polygon light masks. The
-- lit mask draws the head-on white light, the zero mask renders
-- emission-only (black). Canvas readbacks come back Y-inverted on some GL
-- drivers, so each triangle is sampled at both its canonical position and
-- its mirrored position; exactly one of the two is interior in any
-- environment. The readback scale is likewise driver-dependent (0..255 or
-- 0..1), so the brightness threshold is derived from an actual sample.
function T.polygon_light_mask_changes_the_rendered_result(scope)
  local renderer = scope:own(MapRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  local white = 31 + 31 * 32 + 31 * 1024
  runtime.lighting = {
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
  }
  -- A lit vertex (color source 3) with a +Z normal, so the head-on light
  -- contributes full diffuse. With the identity camera the triangle covers
  -- the lower-right half of the viewport (the shader flips clip Y).
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local function sample(mask)
    renderer:draw(runtime, camera, {
      {
        {
          mesh = mesh,
          material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
          transform = IDENTITY,
          modelNormal = IDENTITY_NORMAL,
          alphaClass = "opaque",
          cullMode = "back",
          polygonAlpha = 1.0,
          polygonMode = "modulation",
          polygonId = 0,
          lightMask = mask,
          alphaCutoff = 0.5 / 255,
          center = { 0.5, 0.5, 0 },
        },
      },
    }, viewport)
    local img = renderer.sceneColor:newImageData()
    -- NDC (0.3, -0.6) is well inside the triangle; 95 is the Y-mirror of 384.
    local lit = { img:getPixel(416, 384) }
    local mirrored = { img:getPixel(416, 95) }
    return lit, mirrored
  end

  local lit, litMirrored = sample(1)
  local unlit, unlitMirrored = sample(0)

  local function brightest(a, b)
    return math.max(a[1], a[2], a[3], b[1], b[2], b[3])
  end
  local threshold = brightest(lit, litMirrored) / 2
  Assert.isTrue(threshold > 0, "the lit mask frame must have a sample to derive a threshold from")
  Assert.isTrue(
    lit[1] >= threshold and lit[2] >= threshold and lit[3] >= threshold
      or litMirrored[1] >= threshold and litMirrored[2] >= threshold and litMirrored[3] >= threshold,
    "the lit mask renders bright at the interior sample"
  )
  Assert.isTrue(unlit[1] < threshold and unlit[2] < threshold and unlit[3] < threshold, "mask 0 renders dark")
  Assert.isTrue(
    unlitMirrored[1] < threshold and unlitMirrored[2] < threshold and unlitMirrored[3] < threshold,
    "mask 0 renders dark at the mirrored sample"
  )
end

-- A static item (a material record without matEmission) must pass the
-- profile's emission through unchanged: the shader multiplies the emission
-- register by the identity u_matEmission default, so an emission-only scene
-- still renders. Regression: the emission multiplier defaulted to black,
-- blacking out every static item -- building sides and sprites were far too
-- dark vs the DS, whose field profile emission is a large part of their
-- brightness.
function T.emission_passes_through_for_static_materials(scope)
  local renderer = scope:own(MapRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = 0,
        ambientRgb555 = 0,
        specularRgb555 = 0,
        emissionRgb555 = 25 + 25 * 32 + 25 * 1024,
      },
    },
  }
  -- A NORMAL-lit vertex (color source 3) with a +Z normal; every light is
  -- disabled, so only the emission register can produce color.
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  renderer:draw(runtime, camera, {
    {
      {
        mesh = mesh,
        material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
        transform = IDENTITY,
        modelNormal = IDENTITY_NORMAL,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 0,
        alphaCutoff = 0.5 / 255,
        center = { 0.5, 0.5, 0 },
      },
    },
  }, viewport)
  local img = renderer.sceneColor:newImageData()
  -- Emission 25/31 renders at ~0.8 of full scale; the canvas Y-mirror is
  -- driver-dependent, so both the canonical and mirrored interior samples
  -- are read and the scale is derived from the readback itself.
  local function maxChannel(x, y)
    local r, g, b = img:getPixel(x, y)
    return math.max(r, g, b)
  end
  local a, b = maxChannel(416, 384), maxChannel(416, 95)
  local peak = math.max(a, b)
  local scale = peak > 1 and 255 or 1
  Assert.isTrue(peak >= 0.6 * scale, "the emission register renders bright for a static material")
end

-- A dynamic material's stored colors must never dim the field profile: the
-- HGSS field engine overrides every material's stored registers with the
-- profile values (the field-model policy clears all four color ownership
-- bits), so a material carrying a colors block -- but no playing NSBMA
-- color clip -- still renders with the profile's colors. Regression: the
-- stored colors multiplied the profile, so a stored diffuse of ~100/255
-- dimmed a lit surface to under half brightness.
function T.stored_material_colors_never_dim_the_profile(scope)
  local renderer = scope:own(MapRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  local white = 31 + 31 * 32 + 31 * 1024
  runtime.lighting = {
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
        emissionRgb555 = 0,
      },
    },
  }
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  renderer:draw(runtime, camera, {
    {
      {
        mesh = mesh,
        -- A dynamic material with the four DS registers stored, but no NSBMA
        -- clip driving them: the profile must win every channel.
        material = {
          alphaClass = "opaque",
          matDiffuse = { 100 / 255, 100 / 255, 100 / 255 },
          matAmbient = { 0, 0, 0 },
          matSpecular = { 0, 0, 0 },
          matEmission = { 0, 0, 0 },
          texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        },
        transform = IDENTITY,
        modelNormal = IDENTITY_NORMAL,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 15,
        alphaCutoff = 0.5 / 255,
        center = { 0.5, 0.5, 0 },
      },
    },
  }, viewport)
  local img = renderer.sceneColor:newImageData()
  -- The profile's white ambient + head-on white diffuse saturate the vertex:
  -- full brightness, not the stored colors' ~0.4.
  local function maxChannel(x, y)
    local r, g, b = img:getPixel(x, y)
    return math.max(r, g, b)
  end
  local a, b = maxChannel(416, 384), maxChannel(416, 95)
  local peak = math.max(a, b)
  local scale = peak > 1 and 255 or 1
  Assert.isTrue(peak >= 0.6 * scale, "the profile colors render, not the stored material colors")
end

-- A playing NSBMA color clip replaces the field profile at the register
-- level: the animated diffuse must render at its own value, not at the
-- profile value multiplied by it. Regression: the animated colors
-- multiplied the profile, so a full-white animated diffuse over a dim
-- profile diffuse rendered at the profile's brightness.
function T.color_animated_materials_replace_the_profile(scope)
  local renderer = scope:own(MapRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  local white = 31 + 31 * 32 + 31 * 1024
  local dim = 10 + 10 * 32 + 10 * 1024
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = true, colorRgb555 = white, vectorFx12 = { 0, 0, -4096 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = dim,
        ambientRgb555 = 0,
        specularRgb555 = 0,
        emissionRgb555 = 0,
      },
    },
  }
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  renderer:draw(runtime, camera, {
    {
      {
        mesh = mesh,
        -- A material whose colors an NSBMA clip drives: the clip's sampled
        -- colors are the registers, so a full-white animated diffuse renders
        -- full, never the dim profile diffuse.
        material = {
          alphaClass = "opaque",
          matDiffuse = { 1, 1, 1 },
          colorsAnimated = true,
          texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        },
        transform = IDENTITY,
        modelNormal = IDENTITY_NORMAL,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 15,
        alphaCutoff = 0.5 / 255,
        center = { 0.5, 0.5, 0 },
      },
    },
  }, viewport)
  local img = renderer.sceneColor:newImageData()
  local function maxChannel(x, y)
    local r, g, b = img:getPixel(x, y)
    return math.max(r, g, b)
  end
  local a, b = maxChannel(416, 384), maxChannel(416, 95)
  local peak = math.max(a, b)
  local scale = peak > 1 and 255 or 1
  Assert.isTrue(peak >= 0.6 * scale, "the animated diffuse renders at its own value, not the profile's")
end

-- A scene with no lighting profile must not inherit the previous lit
-- scene's light/material uniforms: the profile-less draw explicitly sends
-- disabled lights and zero material colors, so a
-- NORMAL-lit vertex and a field-diffuse vertex both render dark after a
-- bright lit frame instead of the lit frame's values. Canvas readbacks come
-- back Y-inverted on some GL drivers, so each triangle is sampled at both
-- its canonical position and its mirrored position; exactly one of the two
-- is interior in any environment. The readback scale is likewise
-- driver-dependent (0..255 or 0..1), so the brightness threshold is derived
-- from an actual sample.
function T.lit_then_unlit_scene_does_not_inherit_lighting(scope)
  local renderer = scope:own(MapRenderer.new())
  local camera = fixedCamera()
  local white = 31 + 31 * 32 + 31 * 1024
  local litRuntime = emptyRuntime()
  litRuntime.lighting = {
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
  }
  local unlitRuntime = emptyRuntime()
  -- Triangle 1 (right half) uses a NORMAL color source, so it is shaded by
  -- the light and material uniforms; triangle 2 (left half) uses the
  -- field-diffuse source and reads the effective material register
  -- (u_matDiffuse).
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2 },
    { -1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2 },
    { 0, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local item = {
    mesh = mesh,
    material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "opaque",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 15,
    alphaCutoff = 0.5 / 255,
    center = { 0.5, 0.5, 0 },
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
  -- head-on light, the field-diffuse triangle from its effective material
  -- register (COLOR_DIFFUSE reads u_matDiffuse, which the profile supplies
  -- for a static item -- the field engine owns every channel).
  renderer:draw(litRuntime, camera, { { item } }, viewport)
  local litImg = renderer.sceneColor:newImageData()
  local sr, sg, sb = litImg:getPixel(0, 0)
  local threshold = (sr > 1 or sg > 1 or sb > 1) and 127 or 0.5
  Assert.isTrue(anyBright(litImg, normalSamples, threshold), "lit frame shades the NORMAL triangle")
  Assert.isTrue(anyBright(litImg, diffuseSamples, threshold), "lit frame shades the field-diffuse triangle")

  -- The profile-less frame must reset every lighting uniform: the NORMAL
  -- triangle may not stay bright from the lit frame's light values, and the
  -- field-diffuse triangle reads the effective material register (u_mat*),
  -- which the unlit frame resets to zero -- nothing supplies the registers
  -- without a profile, so the triangle renders dark instead of inheriting
  -- the previous frame's material colors.
  renderer:draw(unlitRuntime, camera, { { item } }, viewport)
  local unlitImg = renderer.sceneColor:newImageData()
  Assert.isFalse(anyBright(unlitImg, normalSamples, threshold), "unlit frame inherits the previous light state")
  Assert.isFalse(anyBright(unlitImg, diffuseSamples, threshold), "unlit frame inherits the previous material state")
end

function T.a_straddling_item_bends_its_leading_vertices(scope)
  -- An arbitrary injected clear color distinguishable from the drawn
  -- triangles: this test asserts against it directly, not against
  -- MapRenderer's fallback default (libs/engine carries no opinion about
  -- what color a game wants; only that it clears to whatever it is given).
  local clearColor = { 0.08, 0.09, 0.12, 1 }
  local renderer = scope:own(MapRenderer.new({ clearColor = clearColor }))
  local lg = love.graphics

  -- Leading triangle (green) at y in [0.2, 0.5]; trailing triangle (red) at
  -- y in [-0.5, -0.2]. The straddle transform translates the leading half
  -- DOWN one world unit, so the baked green triangle lands at y in [-0.8,
  -- -0.5] -- clearly apart from the red one.
  local mesh = scope:own(syntheticMesh({
    { -0.8, 0.2, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { 0, 0.5, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { 0.8, 0.2, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { -0.8, -0.5, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0 },
    { 0, -0.2, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0 },
    { 0.8, -0.5, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0 },
  }))
  mesh:setVertexMap({ 4, 5, 6, 1, 2, 3 })
  local item = {
    mesh = mesh,
    material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    alphaClass = "opaque",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0, 0, 0 },
    straddle = {
      leading = 3,
      transform = Matrix4.translate(0, -1, 0),
    },
  }

  renderer:draw(emptyRuntime(), fixedCamera(), { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))
  local data = scope:own(renderer.sceneColor:newImageData())
  local w, h = renderer.canvasW, renderer.canvasH
  -- Identity view/projection and the shader's clip-y negation map a world
  -- point (x, y) to canvas pixel ((1+x)/2 * w, (1-y)/2 * h) with row 0 at
  -- the top.
  local function pixelAt(worldX, worldY)
    local cx = math.floor((worldX + 1) / 2 * w + 0.5)
    local cy = math.floor((1 - worldY) / 2 * h + 0.5)
    return data:getPixel(cx, cy)
  end

  -- The baked leading triangle (world y in [-0.8, -0.5]): centroid green.
  local gr, gg, gb = pixelAt(0, -0.65)
  Assert.near(gr, 0, 0.05, "baked leading red")
  Assert.near(gg, 1, 0.05, "baked leading green")
  Assert.near(gb, 0, 0.05, "baked leading blue")
  -- The trailing triangle (world y in [-0.5, -0.2]): centroid red.
  local rr, rg, rb = pixelAt(0, -0.35)
  Assert.near(rr, 1, 0.05, "trailing red")
  Assert.near(rg, 0, 0.05, "trailing green")
  Assert.near(rb, 0, 0.05, "trailing blue")
  -- Where the unbaked leading triangle would have drawn (world y in
  -- [0.2, 0.5]): nothing but the background color.
  local br, bg, bb = pixelAt(0, 0.35)
  Assert.near(br, clearColor[1], 0.05, "unbaked position red")
  Assert.near(bg, clearColor[2], 0.05, "unbaked position green")
  Assert.near(bb, clearColor[3], 0.05, "unbaked position blue")
end

-- A lighting profile with one white light and a specular-only material
-- (diffuse/ambient/emission zero), so any brightness in the frame is pure
-- specular. The two cos(2a) scenarios below share it.
local function specularOnlyRuntime(vectorFx12)
  local white = 31 + 31 * 32 + 31 * 1024
  local runtime = emptyRuntime()
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = true, colorRgb555 = white, vectorFx12 = vectorFx12 },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = 0,
        ambientRgb555 = 0,
        specularRgb555 = 14 + 14 * 32 + 16 * 1024,
        emissionRgb555 = 0,
      },
    },
  }
  return runtime
end

-- A NORMAL-lit triangle (color source 3) with the given normal, covering the
-- lower-right half of the viewport under the identity camera (the shader
-- flips clip Y, exactly like polygon_light_mask_changes_the_rendered_result).
local function litMesh(scope, normal)
  local function vertex(x, y)
    return { x, y, 0, 0, 1, normal[1], normal[2], normal[3], 1, 1, 1, 1, 3 }
  end
  return scope:own(syntheticMesh({ vertex(0, 0), vertex(1, 0), vertex(0, 1) }))
end

-- Brightest channel over the two candidate interior samples of the scene
-- color canvas (readbacks come back Y-inverted on some drivers, so exactly
-- one of the two is interior; the scale is likewise driver-dependent, so
-- comparisons stay relative to a sample of the same frame).
local function brightestSample(renderer)
  local img = renderer.sceneColor:newImageData()
  local function maxOf(p)
    return math.max(p[1], p[2], p[3])
  end
  return math.max(maxOf({ img:getPixel(416, 384) }), maxOf({ img:getPixel(416, 95) }))
end

-- Draw one specular-only frame and return its brightest interior sample.
local function specularFrame(renderer, scope, normal, vectorFx12)
  renderer:draw(specularOnlyRuntime(vectorFx12), fixedCamera(), {
    {
      {
        mesh = litMesh(scope, normal),
        material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
        transform = IDENTITY,
        modelNormal = IDENTITY_NORMAL,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 1,
        alphaCutoff = 0.5 / 255,
        center = { 0.5, 0.5, 0 },
      },
    },
  }, FieldViewport.new(640, 480, { mode = "strict" }))
  return brightestSample(renderer)
end

-- The melonDS cos(2a) term narrows the specular highlight: at N(d=0.75)
-- with L = (0,0,-1), dot(N,H) = 0.75 and ls = 2*0.75^2-1 = 0.125, so the
-- frame renders 2/31 after round-half-up quantization, well below half of
-- the head-on 14/31 frame (a raw half-vector term would render 11/31 and
-- stay above that threshold). The off-axis frame must come out well below
-- half the head-on one either way.
function T.specular_cos2a_narrows_the_highlight_off_axis(scope)
  local renderer = scope:own(MapRenderer.new())
  local headOn = specularFrame(renderer, scope, { 0, 0, 1 }, { 0, 0, -4096 })
  local offAxis = specularFrame(renderer, scope, { 0.661438, 0, 0.75 }, { 0, 0, -4096 })

  Assert.isTrue(headOn > 0, "the head-on specular frame must have a sample to derive a threshold from")
  Assert.isTrue(
    offAxis < headOn / 2,
    "the off-axis specular must be far dimmer than head-on (cos(2a): 2/31 vs 14/31; raw ndh: 11/31)"
  )
end

-- The melonDS front-light gate: a light whose travel direction is behind
-- the surface, dot(-L,N) < 0, must contribute no specular even though its
-- half vector still faces the surface (dot(N,H) = 0.839, so the ungated
-- cos(2a) scalar would be 0.407); the gated shader must render black.
function T.behind_light_specular_stays_dark(scope)
  local renderer = scope:own(MapRenderer.new())
  local headOn = specularFrame(renderer, scope, { 0, 0, 1 }, { 0, 0, -4096 })
  local behind = specularFrame(renderer, scope, { 0.5, 0, 0.8660254037844386 }, { -3313, 0, 2407 })

  Assert.isTrue(headOn > 0, "the head-on specular frame must have a sample to derive a threshold from")
  Assert.isTrue(behind < headOn / 2, "a behind-the-surface light contributes no specular under the melonDS gate")
end

-- ---- terrain-animation offscreen fixtures ----

-- The New Bark flower replacement schedule: R0 for 18 ticks, R1 for 18, R0
-- for 18, R2 for 18, loop (the generated-contract record shape).
local function flowerSteps(flowerPaths)
  return {
    { texture = flowerPaths[1], durationTicks = 18 },
    { texture = flowerPaths[2], durationTicks = 18 },
    { texture = flowerPaths[1], durationTicks = 18 },
    { texture = flowerPaths[3], durationTicks = 18 },
  }
end

-- A compiled texsrt clip in the NsbtaClipCompiler payload shape: one target
-- whose transS curve moves 0x0800 fx32 units (half a texture width -- 8
-- texels on the 16-wide texture) between frame 0 and frame 1.
local function terrainSrtClip()
  return {
    id = "fixture:area00_ani",
    name = "area00_ani",
    category = "material",
    kind = "texsrt",
    frameCount = 2,
    tracks = { { target = "water", targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      targets = {
        {
          index = 0,
          name = "water",
          channels = {
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
            rot = { source = "constant", value = 0x10000000 },
            transS = { source = "curve", rate = 1, limit = 2, storage = "fx32", keys = { 0x0, 0x0800 } },
            transT = { source = "constant", value = 0 },
          },
        },
      },
    },
  }
end

-- One solid-color PNG frame for the swap schedule.
local function solidPng(width, height, r, g, b)
  local data = love.image.newImageData(width, height)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      data:setPixel(x, y, r, g, b, 255)
    end
  end
  return data:encode("png")
end

-- A two-tone PNG: left half red, right half blue, so a half-width texture
-- translation observably moves the sampled texel.
local function twoTonePng(width, height)
  local data = love.image.newImageData(width, height)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if x < width / 2 then
        data:setPixel(x, y, 255, 0, 0, 255)
      else
        data:setPixel(x, y, 0, 0, 255, 255)
      end
    end
  end
  return data:encode("png")
end

-- A full-screen-height quad in world space with UVs spanning [0,1].
local function uvQuad(x0, y0, x1, y1)
  local function v(x, y, u, uv)
    return {
      x = x,
      y = y,
      z = 0,
      u = u,
      v = uv,
      nx = 0,
      ny = 0,
      nz = 1,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end
  return {
    vertices = { v(x0, y0, 0, 0), v(x1, y0, 1, 0), v(x1, y1, 1, 1), v(x0, y1, 0, 1) },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
end

-- A 32x32 all-plain collision grid (the scene cell).
local function collisionGridBytes()
  local cells = {}
  for index = 1, 32 * 32 do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  return CollisionGridAsset.encode({ width = 32, height = 32, cells = cells })
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

-- A terrain scene with two materials: a texture-swap flower quad covering
-- the left half of the screen and a water quad covering the right half,
-- animated by the given SRT clip. Returns the cache facade.
local function terrainAnimationScene(flowerFrames, waterPng, srtClip)
  local mapId = 61
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(mapId)
  local flowerPaths = {}
  for i, png in ipairs(flowerFrames) do
    local path = MapAssetCache.texturePath("flower-f" .. i)
    backend:write(path, png)
    flowerPaths[i] = path
  end
  local waterPath = MapAssetCache.texturePath("water")
  backend:write(waterPath, waterPng)

  local flowerQuad = MapAssetCache.geometryPath("flower-quad")
  local waterQuad = MapAssetCache.geometryPath("water-quad")
  backend:write(flowerQuad, MeshWriter.encode(uvQuad(-1, -1, 0, 1)))
  backend:write(waterQuad, MeshWriter.encode(uvQuad(0, -1, 1, 1)))

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
    mapBatches = {
      {
        geometry = flowerQuad,
        material = 0,
        cullMode = "none",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 0,
        alphaClass = "opaque",
      },
      {
        geometry = waterQuad,
        material = 1,
        cullMode = "none",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 0,
        alphaClass = "opaque",
      },
    },
    materials = {
      {
        id = 0,
        name = "flower01",
        texture = flowerPaths[1],
        wrap = { x = "repeat", y = "repeat" },
        texWidth = 16,
        texHeight = 16,
        texMtxMode = 0,
        textureSwap = {
          name = "flower01",
          steps = flowerSteps(flowerPaths),
        },
      },
      {
        id = 1,
        name = "water",
        texture = waterPath,
        wrap = { x = "repeat", y = "repeat" },
        texWidth = 16,
        texHeight = 16,
        texMtxMode = 0,
      },
    },
    buildingInstances = {},
    neighbors = {},
    lighting = nil,
    terrainAnimations = { textureSrt = srtClip },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = zeroFogFixture(),
  }
  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  backend:write(dir .. "/collision.g4collision", collisionGridBytes())
  return luaCache(backend)
end

-- One offscreen scenario for the terrain-animation proof: a single
-- renderer and a single loader boot draw (1) the terrain quad on its base
-- image, (2) the same quad after the clock crossed a texture-swap boundary,
-- asserting the selected pixel changed to the second step's image, and (3)
-- the SRT-targeted quad after a non-identity sample, asserting the sampling
-- moved to the expected texel. Production MapSceneLoader runtime material
-- tables (image + texMatrix, mutated by TerrainMaterialAnimator) drive the
-- draw; nothing here is a test-only shader.
function T.terrain_animation_offscreen_swap_and_srt(scope)
  local flowerFrames = {
    solidPng(16, 16, 255, 0, 0),
    solidPng(16, 16, 0, 0, 255),
    solidPng(16, 16, 0, 255, 0),
  }
  local cache = terrainAnimationScene(flowerFrames, twoTonePng(16, 16), terrainSrtClip())
  local scene = assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua"))
  local runtime = scope:own(MapSceneLoader.load(cache, scene))
  local renderer = scope:own(MapRenderer.new())
  local camera = fixedCamera()
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  -- World position -> canvas pixel under the identity camera (the shader
  -- flips clip Y). Both quads span the full canvas height, so the mirrored
  -- row (used on drivers whose readbacks come back Y-inverted) is interior
  -- too.
  local function pixelAt(w, h, x, y)
    return math.floor((x + 1) / 2 * w + 0.5), math.floor((1 - y) / 2 * h + 0.5)
  end
  local flowerX, flowerY = pixelAt(640, 480, -0.25, 0.25)
  local waterX, waterY = pixelAt(640, 480, 0.625, 0.125)
  local flowerMirrorY = 480 - 1 - flowerY
  local waterMirrorY = 480 - 1 - waterY

  local function draw()
    renderer:draw(runtime, camera, { runtime.mapDraws }, viewport)
    return renderer.sceneColor:newImageData()
  end

  -- The readback scale is driver-dependent (0..255 or 0..1), so channels
  -- are compared against a scale derived from the sampled pixel itself.
  local function isColor(pixel, r, g, b)
    local scale = pixel[1] > 1 and 255 or 1
    local function channel(value, want)
      return want == 0 and value <= 0.4 * scale or value >= 0.6 * scale
    end
    return channel(pixel[1], r) and channel(pixel[2], g) and channel(pixel[3], b)
  end

  local function assertPixel(img, x, y, r, g, b, label)
    local p = { img:getPixel(x, y) }
    Assert.isTrue(
      isColor(p, r, g, b),
      label .. " at (" .. x .. "," .. y .. "): got " .. p[1] .. "," .. p[2] .. "," .. p[3]
    )
  end

  -- The initial draw: the swap material binds its base image (red -- the
  -- fixture's replacement step 1 shares the path) and the SRT target
  -- samples its identity matrix (the water quad's u=0.625 samples the blue
  -- half). Loading established the base image without advancing.
  local img0 = draw()
  assertPixel(img0, flowerX, flowerY, 1, 0, 0, "flower frame 0 renders red")
  assertPixel(img0, flowerX, flowerMirrorY, 1, 0, 0, "flower frame 0 renders red (mirror row)")
  assertPixel(img0, waterX, waterY, 0, 0, 1, "water frame 0 samples the blue half")
  assertPixel(img0, waterX, waterMirrorY, 0, 0, 1, "water frame 0 samples the blue half (mirror row)")

  -- One fixed tick applies the first non-identity SRT sample (half a
  -- texture width -- 8 texels -- moves the sample from blue to red). The
  -- flower clock has not reached its first switch (tick 19), so the flower
  -- stays on the base image.
  runtime:updateAnimated()
  local img1 = draw()
  assertPixel(img1, waterX, waterY, 1, 0, 0, "water frame 1 samples the red half after the SRT move")
  assertPixel(img1, waterX, waterMirrorY, 1, 0, 0, "water frame 1 samples the red half (mirror row)")
  assertPixel(img1, flowerX, flowerY, 1, 0, 0, "flower stays on the base image before the swap boundary")

  -- Crossing the texture-swap boundary (18 more ticks, first switch at tick
  -- 19): the runtime material image switches to the second step's image and
  -- the quad renders blue. The 2-frame SRT clip is at frame 19 mod 2 = 1,
  -- so the water sample stays shifted.
  for _ = 1, 18 do
    runtime:updateAnimated()
  end
  local img2 = draw()
  assertPixel(img2, flowerX, flowerY, 0, 0, 1, "flower switched to the second step image at the swap boundary")
  assertPixel(img2, flowerX, flowerMirrorY, 0, 0, 1, "flower switched to the second step image (mirror row)")
  assertPixel(img2, waterX, waterY, 1, 0, 0, "water keeps the shifted sample")
end

-- The shader's depth quantization range comes from the active camera's real
-- far clipping plane (u_depthWMax), not a fixed field-draw-distance bound
-- baked into the shader. With the identity view/projection/model this test
-- drives, clip.w is exactly 1 so linearEyeDepth (dsWbufferDepth's argument)
-- is exactly 1 -- the only free variable across the two draws below is the
-- camera's far plane, so a real difference in the readback proves the value
-- reaches the shader and is used, not merely accepted and ignored.
function T.camera_far_plane_drives_the_normalized_depth_target(scope)
  local renderer = scope:own(MapRenderer.new())
  local image = solidAlphaImage(scope, 255, 255, 255, 255)
  local item = decalItem(decalTriangle(scope), image)
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local DS_DEPTH_MAX = 16777215.0

  -- Whichever of the two candidate interior samples is not the rear-plane
  -- clear (r == 1.0, the normalized sentinel) carries the drawn item's own
  -- id (0) and real quantized depth in its green channel.
  local function idDepthInterior(camera)
    renderer:draw(emptyRuntime(), camera, { { item } }, viewport)
    local img = renderer.idDepth:newImageData()
    local a, b = { img:getPixel(416, 384) }, { img:getPixel(416, 95) }
    return a[1] < 0.5 and a or b
  end

  local function expectedDepth(far)
    return math.floor(math.min(1, 1 / far) * DS_DEPTH_MAX)
  end

  local shortRange = fixedCamera()
  shortRange.far = 2
  local shortRangeSample = idDepthInterior(shortRange)

  local longRange = fixedCamera()
  longRange.far = 4
  local longRangeSample = idDepthInterior(longRange)

  Assert.isTrue(
    shortRangeSample[2] ~= longRangeSample[2],
    "changing the camera's far plane must change the quantized depth for identical eye-space geometry"
  )
  Assert.near(shortRangeSample[2], expectedDepth(2), 1, "matches dsWbufferDepth(1) at u_depthWMax=2")
  Assert.near(longRangeSample[2], expectedDepth(4), 1, "matches dsWbufferDepth(1) at u_depthWMax=4")
end

-- F: the edge pass's ID/depth target carries the rear-plane/wireframe
-- sentinel (255, outside the real 0-63 polygon-id domain -- see
-- MapRenderer.REAR_PLANE_ID) at every wireframe draw's own center, not only
-- at the background clear. A sentinel-valued center adjacent to a real,
-- differently-id'd, farther neighbor must still be recognized as "marked"
-- (different id, center in front) without ever indexing u_edgeColors[8]
-- with a sentinel-derived value (255/8 = 31, out of the table's 0-7 range):
-- the guard must return the unmodified scene color instead. This drives
-- edge.glsl directly (not through MapRenderer's full draw path) so the
-- neighbor/center ID and depth values are exact and independent of any
-- particular mesh/camera geometry.
function T.edge_shader_never_indexes_the_color_table_for_a_sentinel_center(scope)
  local edgeShader = scope:own(MapRenderer.new()).edgeShader

  -- A 3x1 idTex: two real, differently-id'd, farther neighbors flank a
  -- sentinel-id (255) center that is nearer than both -- exactly the
  -- shape a wireframe draw adjacent to opaque geometry produces.
  local idData = love.image.newImageData(3, 1, "rgba32f")
  idData:setPixel(0, 0, 38 / 255, 1000, 0, 1)
  idData:setPixel(1, 0, 255 / 255, 10, 0, 1)
  idData:setPixel(2, 0, 51 / 255, 2000, 0, 1)
  local idImage = scope:own(love.graphics.newImage(idData))
  idImage:setFilter("nearest", "nearest")

  -- The pre-edge scene color at the sentinel pixel: a value distinct from
  -- every entry in u_edgeColors below, so an out-of-range table read
  -- (rather than the required unmodified-scene guard) is distinguishable.
  local sceneData = love.image.newImageData(3, 1)
  sceneData:setPixel(0, 0, 0.2, 0.2, 0.2, 1)
  sceneData:setPixel(1, 0, 100 / 255, 150 / 255, 200 / 255, 1)
  sceneData:setPixel(2, 0, 0.2, 0.2, 0.2, 1)
  local sceneImage = scope:own(love.graphics.newImage(sceneData))
  sceneImage:setFilter("nearest", "nearest")

  local edgeColors = {}
  for i = 0, 7 do
    edgeColors[i + 1] = { i / 10, i / 10, i / 10 }
  end

  local target = scope:own(love.graphics.newCanvas(3, 1))
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setShader(edgeShader)
  edgeShader:send("u_idTex", idImage)
  edgeShader:send("u_texelSize", { 1 / 3, 1 })
  edgeShader:send("u_edgeRadius", 1)
  edgeShader:send("u_edgeColors", unpack(edgeColors))
  love.graphics.draw(sceneImage, 0, 0)
  love.graphics.setShader()
  love.graphics.setCanvas()

  local out = target:newImageData()
  local r, g, b = out:getPixel(1, 0)
  Assert.near(r, 100 / 255, 1 / 255, "sentinel center must render the unmodified scene color's red channel")
  Assert.near(g, 150 / 255, 1 / 255, "sentinel center must render the unmodified scene color's green channel")
  Assert.near(b, 200 / 255, 1 / 255, "sentinel center must render the unmodified scene color's blue channel")
end

-- Shared 3x1 fixture for the four edge-predicate anchors below: pixel 1 is
-- always the center under test, pixels 0/2 its left/right neighbors
-- (u_edgeRadius=1 samples only the immediate neighbor). Drives edge.glsl
-- directly, the same idiom
-- edge_shader_never_indexes_the_color_table_for_a_sentinel_center uses, so
-- the id/depth/translucent-flag inputs are exact and independent of any
-- particular mesh/camera geometry. Returns the center pixel's rendered RGB.
local function runEdgePass(scope, pixels, edgeColors)
  local edgeShader = scope:own(MapRenderer.new()).edgeShader

  local idData = love.image.newImageData(3, 1, "rgba32f")
  for i, p in ipairs(pixels) do
    idData:setPixel(i - 1, 0, p.id / 255, p.depth, p.translucent and 1 or 0, 1)
  end
  local idImage = scope:own(love.graphics.newImage(idData))
  idImage:setFilter("nearest", "nearest")

  -- A center scene color distinct from every u_edgeColors entry below, so
  -- "no edge" (unmodified scene) is distinguishable from "edge" (a table
  -- entry) or a garbage/out-of-range read.
  local sceneData = love.image.newImageData(3, 1)
  sceneData:setPixel(0, 0, 0.2, 0.2, 0.2, 1)
  sceneData:setPixel(1, 0, 200 / 255, 210 / 255, 220 / 255, 1)
  sceneData:setPixel(2, 0, 0.2, 0.2, 0.2, 1)
  local sceneImage = scope:own(love.graphics.newImage(sceneData))
  sceneImage:setFilter("nearest", "nearest")

  local target = scope:own(love.graphics.newCanvas(3, 1))
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setShader(edgeShader)
  edgeShader:send("u_idTex", idImage)
  edgeShader:send("u_texelSize", { 1 / 3, 1 })
  edgeShader:send("u_edgeRadius", 1)
  edgeShader:send("u_edgeColors", unpack(edgeColors))
  love.graphics.draw(sceneImage, 0, 0)
  love.graphics.setShader()
  love.graphics.setCanvas()

  local out = target:newImageData()
  return { out:getPixel(1, 0) }
end

-- Eight distinct, non-uniform edge colors (the same fixture the sentinel
-- test uses): entry i is (i/10, i/10, i/10), so an edge render is
-- distinguishable from every other entry and from the scene color.
local function eightEdgeColors()
  local colors = {}
  for i = 0, 7 do
    colors[i + 1] = { i / 10, i / 10, i / 10 }
  end
  return colors
end

-- Edge behavior anchor 1: a real, differently-id'd neighbor strictly
-- farther than the center (the center is "in front") marks an edge,
-- rendering u_edgeColors[centerId/8] -- id 20 -> entry 20/8 = 2 -> (0.2,
-- 0.2, 0.2).
function T.edge_shader_marks_a_differently_id_neighbor_when_center_is_in_front(scope)
  local out = runEdgePass(scope, {
    { id = 10, depth = 1000 },
    { id = 20, depth = 500 },
    { id = 20, depth = 500 },
  }, eightEdgeColors())
  Assert.near(out[1], 0.2, 1 / 255, "a marked edge renders u_edgeColors[centerId/8] (entry 2, 0.2,0.2,0.2)")
  Assert.near(out[2], 0.2, 1 / 255)
  Assert.near(out[3], 0.2, 1 / 255)
end

-- Edge behavior anchor 2: a differently-id'd neighbor at the SAME depth as
-- the center is not strictly "in front" (the comparison has no tolerance),
-- so no edge fires even though the id differs -- this is what suppresses
-- coplanar boundaries between adjacent same-depth batches.
function T.edge_shader_does_not_mark_a_differently_id_neighbor_at_equal_depth(scope)
  local out = runEdgePass(scope, {
    { id = 10, depth = 500 },
    { id = 20, depth = 500 },
    { id = 20, depth = 500 },
  }, eightEdgeColors())
  Assert.near(out[1], 200 / 255, 1 / 255, "equal depth must not mark: unmodified scene color")
  Assert.near(out[2], 210 / 255, 1 / 255)
  Assert.near(out[3], 220 / 255, 1 / 255)
end

-- Edge behavior anchor 3: a neighbor sharing the center's own polygon id
-- never marks, regardless of depth -- a same-id boundary is never a real
-- silhouette.
function T.edge_shader_does_not_mark_a_same_id_neighbor(scope)
  local out = runEdgePass(scope, {
    { id = 20, depth = 1000 },
    { id = 20, depth = 500 },
    { id = 20, depth = 500 },
  }, eightEdgeColors())
  Assert.near(out[1], 200 / 255, 1 / 255, "same polygon id must not mark: unmodified scene color")
  Assert.near(out[2], 210 / 255, 1 / 255)
  Assert.near(out[3], 220 / 255, 1 / 255)
end

-- Edge behavior anchor 4: a translucent center (the blue-channel
-- translucent-attribute flag) is never an edge center, even under the exact
-- neighbor/depth shape that marks an opaque center (anchor 1's own
-- fixture) -- translucent draws occlude but are never outlined themselves.
function T.edge_shader_never_marks_a_translucent_center(scope)
  local out = runEdgePass(scope, {
    { id = 10, depth = 1000 },
    { id = 20, depth = 500, translucent = true },
    { id = 20, depth = 500 },
  }, eightEdgeColors())
  Assert.near(out[1], 200 / 255, 1 / 255, "a translucent center must not mark: unmodified scene color")
  Assert.near(out[2], 210 / 255, 1 / 255)
  Assert.near(out[3], 220 / 255, 1 / 255)
end

return GraphicsSmoke.suite(T)
