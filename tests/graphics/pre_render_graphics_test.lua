-- Pre-render preflight coverage: MapRenderer:draw driven through a real
-- graphics context whose `draw` is trapped (PreRenderGraphics), so the entire
-- render-preparation path -- raster sizing, real canvas allocation, filter
-- configuration, shader binding, uniform sends, depth/blend state -- runs
-- against genuine GPU resources but never rasterizes a primitive. This is the
-- pre-render seam the render-state census/corpus acceptance work (Layer 2)
-- and later renderer stories build on; it asserts GPU-preparation
-- correctness, never pixel output (that stays in the ordinary graphics smoke
-- suite, which uses the real love.graphics draw path).

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MapRenderer = require("libs.engine.src.MapRenderer")
local PreRenderGraphics = require("tests.graphics.support.PreRenderGraphics")
local VertexFormat = require("libs.assets.src.VertexFormat")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_NORMAL = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

local function fixedCamera()
  local function identity()
    return IDENTITY
  end
  return { distance = 26, view = identity, projection = identity, billboardProjection = identity }
end

local function emptyRuntime()
  return {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
  }
end

local function syntheticMesh(vertices)
  return love.graphics.newMesh(VertexFormat.LAYOUT, vertices, "triangles", "static")
end

local function triangleMesh(scope)
  return scope:own(syntheticMesh({
    { -1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 2, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1 },
  }))
end

-- Shared fields every synthetic draw item needs regardless of pass; each
-- per-pass builder below overrides only what makes that pass distinct.
local function baseItem(scope, alphaClass)
  return {
    mesh = triangleMesh(scope),
    material = { alphaClass = alphaClass, texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = alphaClass,
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0, 1, 0 },
  }
end

local function opaqueTriangleItem(scope)
  return baseItem(scope, "opaque")
end

local function cutoutTriangleItem(scope)
  return baseItem(scope, "cutout")
end

-- A translucent item exercises the depth-write toggle the translucent pass
-- derives per item (translucentDepthWrite -> write enabled) and the
-- alphamultiply blend mode the pass switches to before drawing any
-- translucent item. depthEqual is still set here to prove the sentinel fires
-- regardless of its value; MapRenderer's own retirement of the depthEqual ->
-- "lequal" branch is pinned in map_renderer_test.lua, not here -- this test
-- only proves the pass reaches its first mesh draw, never depth-mode
-- specifics.
local function translucentTriangleItem(scope)
  local item = baseItem(scope, "translucent")
  item.depthEqual = true
  item.translucentDepthWrite = true
  return item
end

-- A wireframe item (polygon alpha zero on real DS content) takes the
-- dedicated _drawWireframe/_drawWireframeMesh path: no material/texture
-- uniforms, a separate lg.setWireframe(true) toggle, and the rear-plane
-- sentinel polygon id baked into the shader send rather than the item's own.
local function wireframeTriangleItem(scope)
  local item = baseItem(scope, "wireframe")
  item.polygonAlpha = 0.0
  return item
end

-- An ordinary billboard actor: billboardProjection selects the camera's
-- depth-biased projection matrix, and billboardCenter/billboardScale route
-- _drawMesh's isBillboard branch (u_billboardCenter/u_billboardScale instead
-- of u_model/u_modelNormal) rather than the plain transform branch every
-- other synthetic item above exercises.
local function billboardTriangleItem(scope)
  local item = baseItem(scope, "opaque")
  item.transform = nil
  item.modelNormal = nil
  item.billboardProjection = true
  item.billboardCenter = { 0, 1, 0 }
  item.billboardScale = { 1, 1, 1 }
  return item
end

-- Empty-world preflight: with no draw items, MapRenderer:draw must derive
-- raster dimensions, allocate real canvases, configure filters, bind the
-- shaders and MRT targets, send target-dependent uniforms, clear, and build
-- an empty queue -- then reach the final sceneColor presentation draw, where
-- the trapped `draw` raises the sentinel. Zero primitives are rasterized.
function T.empty_world_preflight_stops_at_the_final_composite_draw(scope)
  local lg = love.graphics
  local canvas = lg.getCanvas()
  local shader = lg.getShader()
  local blendMode, blendAlpha = lg.getBlendMode()
  local depthMode, depthWrite = lg.getDepthMode()
  local cullMode = lg.getMeshCullMode()
  local wireframe = lg.isWireframe()
  local color = { lg.getColor() }

  local renderer = scope:own(MapRenderer.new({ graphics = PreRenderGraphics.new() }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  local err = Assert.throws(function()
    renderer:draw(emptyRuntime(), fixedCamera(), nil, viewport)
  end, "expected the preflight draw to raise the pre-render sentinel")
  Assert.isTrue(
    tostring(err):find(PreRenderGraphics.PRE_RENDER_STOP, 1, true) ~= nil,
    "expected the pre-render sentinel, got " .. tostring(err)
  )

  -- Preparation actually ran against real GPU resources: raster dimensions
  -- were derived and real canvases were allocated and filtered.
  Assert.equal(renderer.canvasW, 640)
  Assert.equal(renderer.canvasH, 480)
  Assert.notNil(renderer.sceneColor)
  Assert.notNil(renderer.idDepth)
  local minFilter, magFilter = renderer.idDepth:getFilter()
  Assert.equal(minFilter, "nearest")
  Assert.equal(magFilter, "nearest")

  -- No primitive was ever rasterized.
  Assert.equal(renderer.stats.drawCalls, 0, "the sentinel must fire before any mesh or composite draw call")

  -- The caller's real graphics state is restored exactly, even though the
  -- draw failed partway through: this is the same caller-state contract the
  -- production draw provides on any other failure path.
  Assert.equal(lg.getCanvas(), canvas)
  Assert.equal(lg.getShader(), shader)
  local restoredBlend, restoredAlpha = lg.getBlendMode()
  Assert.equal(restoredBlend, blendMode)
  Assert.equal(restoredAlpha, blendAlpha)
  local restoredDepth, restoredWrite = lg.getDepthMode()
  Assert.equal(restoredDepth, depthMode)
  Assert.equal(restoredWrite, depthWrite)
  Assert.equal(lg.getMeshCullMode(), cullMode)
  Assert.equal(lg.isWireframe(), wireframe)
  local r, g, b, a = lg.getColor()
  Assert.equal(r, color[1])
  Assert.equal(g, color[2])
  Assert.equal(b, color[3])
  Assert.equal(a, color[4])
end

-- Drives one synthetic item through MapRenderer:draw and asserts the
-- pre-render sentinel fired before any primitive was rasterized. Shared by
-- every per-pass preflight scenario below: each supplies exactly one item so
-- the sentinel is known to fire inside that item's own pass.
local function assertPassStopsBeforeItsFirstDraw(scope, item, passLabel)
  local renderer = scope:own(MapRenderer.new({ graphics = PreRenderGraphics.new() }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  local err = Assert.throws(function()
    renderer:draw(emptyRuntime(), fixedCamera(), { { item } }, viewport)
  end, "expected the " .. passLabel .. " pass draw to raise the pre-render sentinel")
  Assert.isTrue(
    tostring(err):find(PreRenderGraphics.PRE_RENDER_STOP, 1, true) ~= nil,
    "expected the pre-render sentinel, got " .. tostring(err)
  )
  Assert.equal(renderer.stats.drawCalls, 0, "the sentinel must fire before the item's mesh is drawn")
end

-- Per-pass preflight: with one opaque item queued, the sentinel fires at the
-- first attempted mesh draw (inside the opaque pass), proving queue
-- classification, projection selection, shader/material/texture uniform
-- sends, and cull/depth state all ran before the trap -- without drawing the
-- primitive.
function T.opaque_item_preflight_stops_before_its_first_mesh_draw(scope)
  assertPassStopsBeforeItsFirstDraw(scope, opaqueTriangleItem(scope), "opaque")
end

-- Cutout pass: same _drawMesh body as opaque but a distinct alpha-mode
-- uniform and queue bucket; proves cutout classification and shader discard
-- setup complete before the trap.
function T.cutout_item_preflight_stops_before_its_first_mesh_draw(scope)
  assertPassStopsBeforeItsFirstDraw(scope, cutoutTriangleItem(scope), "cutout")
end

-- Translucent pass: proves the alphamultiply blend-mode switch and the
-- per-item depth-compare/write toggle (depthEqual, translucentDepthWrite) run
-- -- along with the translucent-sentinel polygon id override -- before the
-- trap fires on the item's mesh draw.
function T.translucent_item_preflight_stops_before_its_first_mesh_draw(scope)
  assertPassStopsBeforeItsFirstDraw(scope, translucentTriangleItem(scope), "translucent")
end

-- Wireframe pass: proves the dedicated _drawWireframe/_drawWireframeMesh path
-- -- setWireframe(true), the rear-plane sentinel id, and the untextured
-- material registers -- runs before the trap fires on the edge mesh draw.
function T.wireframe_item_preflight_stops_before_its_first_mesh_draw(scope)
  assertPassStopsBeforeItsFirstDraw(scope, wireframeTriangleItem(scope), "wireframe")
end

-- Ordinary billboard actor: proves the depth-biased billboard projection
-- selection and the isBillboard uniform branch (u_billboardCenter/Scale in
-- place of u_model/u_modelNormal) run before the trap fires on the mesh draw.
function T.billboard_item_preflight_stops_before_its_first_mesh_draw(scope)
  assertPassStopsBeforeItsFirstDraw(scope, billboardTriangleItem(scope), "billboard")
end

return GraphicsSmoke.suite(T)
