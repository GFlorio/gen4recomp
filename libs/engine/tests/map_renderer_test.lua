-- Pure MapRenderer contracts that need no graphics context: the field-edge
-- radius derivation, the per-draw light-mask encoding, the straddle bend
-- bake, and the scene-schema gate. Everything that compiles a shader,
-- allocates a render target, or reads back driver state lives in
-- map_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local FieldViewport = require("libs.engine.src.FieldViewport")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local BillboardTransform = require("libs.engine.src.BillboardTransform")

local T = {}

-- Eight zero-based RGB555-packed edge colors, the shape
-- MapAssetCompiler now emits (HgssFieldEdgeColors.TABLE_A/TABLE_B) and
-- MapRenderer decodes at draw time -- distinct, arbitrary packed values so a
-- decode bug (wrong channel, wrong index) cannot hide behind a uniform grey
-- fixture.
local function edgeColorsFixture()
  return { [0] = 0, 1 + 2 * 32 + 3 * 1024, 4, 5 * 32, 6 * 1024, 7, 8 + 8 * 32, 9 }
end

-- The exact decode MapRenderer applies to a packed RGB555 edge-color entry:
-- each 5-bit channel normalized to 0..1. Mirrors MapRenderer's private
-- decodeRgb555 so tests assert against the documented contract, not an
-- internal helper.
local function decodeRgb555Float(packed)
  return {
    (packed % 32) / 31,
    (math.floor(packed / 32) % 32) / 31,
    (math.floor(packed / 1024) % 32) / 31,
  }
end

-- An empty scene and camera for the restoration-contract tests: the renderer
-- draws nothing but still binds/unbinds canvases, shaders, and state.
local function emptySceneCamera()
  local identity = Matrix4.identity()
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
      -- Edge colors are scene state fed from the compiled area's
      -- real HGSS table, never a MapRenderer constructor invariant.
      edgeColors = edgeColorsFixture(),
    },
  }
end

-- Injected graphics for the headless contract tests: a full settable state
-- surface (canvas, shader, blend, depth, wireframe, cull, color) that the
-- renderer must restore exactly, stub shaders/canvases for construction, and
-- failOnNewShader/failOnNewCanvas/failOnDrawCall injection on the Nth call so
-- the construction and draw error paths run without a GL context.
---@param opts table|nil
local function fakeGraphics(opts)
  opts = opts or {}
  local shaders, canvases = {}, {}
  local shaderCount, canvasCount, drawCalls = 0, 0, 0
  local calls = {
    canvas = {},
    blend = {},
    depth = {},
    wireframe = {},
    clear = {},
  }
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
    calls = calls,
    getDrawCalls = function()
      return drawCalls
    end,
    newShader = function(source)
      shaderCount = shaderCount + 1
      if opts.failOnNewShader == shaderCount then
        error("injected shader failure")
      end
      local shaderIndex = shaderCount
      local sendCount = 0
      local shader = { source = source, releaseCount = 0, sends = {}, uniforms = {} }
      shader.send = function(_, name, ...)
        sendCount = sendCount + 1
        if shaderIndex == 2 and opts.failOnEdgeShaderSend == sendCount then
          error("injected edge shader send failure")
        end
        shader.sends[#shader.sends + 1] = { name = name, values = { ... } }
        shader.uniforms[name] = select(1, ...)
      end
      shader.release = function()
        shader.releaseCount = shader.releaseCount + 1
      end
      shaders[#shaders + 1] = shader
      return shader
    end,
    newCanvas = function(w, h, canvasOpts)
      canvasCount = canvasCount + 1
      if opts.failOnNewCanvas == canvasCount then
        error("injected canvas failure")
      end
      -- Records the requested size/format and every setFilter call so raster
      -- target-sizing and nearest-filter contracts can be asserted headlessly.
      local canvas = { releaseCount = 0, w = w, h = h, canvasOpts = canvasOpts }
      canvas.setFilter = function(_, min, mag)
        canvas.filter = { min, mag }
      end
      canvas.release = function()
        canvas.releaseCount = canvas.releaseCount + 1
      end
      canvases[#canvases + 1] = canvas
      return canvas
    end,
    getCanvas = function()
      return state.canvas
    end,
    setCanvas = function(canvas)
      state.canvas = canvas
      calls.canvas[#calls.canvas + 1] = canvas
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
      calls.blend[#calls.blend + 1] = { mode = mode, alpha = alpha }
    end,
    getDepthMode = function()
      return state.depthMode, state.depthWrite
    end,
    setDepthMode = function(mode, write)
      state.depthMode, state.depthWrite = mode, write
      calls.depth[#calls.depth + 1] = { mode = mode, write = write }
    end,
    isWireframe = function()
      return state.wireframe
    end,
    setWireframe = function(wireframe)
      state.wireframe = wireframe
      calls.wireframe[#calls.wireframe + 1] = wireframe
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
    clear = function(sceneColor)
      calls.clear[#calls.clear + 1] = sceneColor
    end,
  }
end

local function shaderSendCount(shader, name)
  local count = 0
  for _, send in ipairs(shader.sends) do
    if send.name == name then
      count = count + 1
    end
  end
  return count
end

local function callCount(calls, expected)
  local count = 0
  for _, call in ipairs(calls) do
    local matches = true
    for key, value in pairs(expected) do
      if call[key] ~= value then
        matches = false
      end
    end
    if matches then
      count = count + 1
    end
  end
  return count
end

-- The exact restoration contract: every captured state (canvas, shader,
-- blend, depth, wireframe, cull, color) equals the pre-draw value, never a
-- hard-coded default. The seeded values differ from what the renderer sets
-- (the renderer binds its own canvas/shader, "less"/"alpha" depth and blend,
-- white, and enables wireframe only during a wireframe pass), so each
-- assertion fails unless the restore block runs. Colors round-trip through
-- float32 on some GL drivers, so they are compared within a small tolerance.
local function assertRestoredState(lg, canvas, shader)
  Assert.equal(lg.getCanvas(), canvas)
  Assert.equal(lg.getShader(), shader)
  local blend, alpha = lg.getBlendMode()
  Assert.equal(blend, "add")
  Assert.equal(alpha, "alphamultiply")
  local depthMode, depthWrite = lg.getDepthMode()
  Assert.equal(depthMode, "lequal")
  Assert.equal(depthWrite, true)
  Assert.equal(lg.isWireframe(), false)
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
    Assert.equal(shader.releaseCount, 1, "renderer released every created shader exactly once")
  end
  for _, canvas in ipairs(lg.canvases) do
    Assert.equal(canvas.releaseCount, 1, "renderer released every created canvas exactly once")
  end
  Assert.equal(#lg.shaders, 2, "the two engine shaders were created")
  Assert.equal(#lg.canvases, 3, "the scene, id-depth, and depth canvases were created")
end

-- Six vertices in the project render layout
-- ({x,y,z, u,v, nx,ny,nz, r,g,b,a, colorSource}): a quad strip of two
-- triangles, all normals +z, literal colors.
local function stripVertices()
  return {
    { -1, 0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 2, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 2, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 4, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 4, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
  }
end

function T.field_edge_radius_uses_only_viewport_height()
  Assert.equal(MapRenderer.fieldEdgeRadiusPixels(192), 1)
  Assert.equal(MapRenderer.fieldEdgeRadiusPixels(384), 2)
  Assert.equal(MapRenderer.fieldEdgeRadiusPixels(1080), 6)
end

-- rasterTargetSize is the pure derivation the DS-relative world raster is
-- built on: nil scale never restricts the host resolution; otherwise the
-- raster height is scale * 192 DS lines, clamped so the raster is never
-- upscaled past the presentation viewport (the 320x240 row), and the width
-- follows the display aspect. Every row is the epic's locked pixel-conform
-- table; the 1280x720/1920x1080/2560x1440 rows additionally prove distinct
-- host resolutions at the same aspect and scale collapse onto one raster size
-- so same-aspect resizes can reuse render targets.
function T.rasterTargetSize_matches_the_pixel_conform_table()
  local cases = {
    { 640, 480, 2, 512, 384 },
    { 960, 720, 2, 512, 384 },
    { 1280, 720, 2, 683, 384 },
    { 1920, 1080, 2, 683, 384 },
    { 2560, 1440, 2, 683, 384 },
    { 2560, 720, 2, 1365, 384 },
    { 320, 240, 2, 320, 240 },
    { 1280, 720, nil, 1280, 720 },
  }
  for _, case in ipairs(cases) do
    local displayW, displayH, scale, expectedW, expectedH = case[1], case[2], case[3], case[4], case[5]
    local rasterW, rasterH = MapRenderer.rasterTargetSize(displayW, displayH, scale)
    Assert.equal(rasterW, expectedW, ("%dx%d @ %s -> width"):format(displayW, displayH, tostring(scale)))
    Assert.equal(rasterH, expectedH, ("%dx%d @ %s -> height"):format(displayW, displayH, tostring(scale)))
  end
end

function T.rejects_stale_scene_schema()
  local ok, err = pcall(MapSceneLoader.load, nil, { schema = "g4-map-scene-v1" })
  Assert.isTrue(
    not ok and err.code == "MAP_SCENE_UNSUPPORTED_SCHEMA",
    "rejects old scene schema: " .. tostring(err.code)
  )
end

-- Exact caller-state restoration: every captured caller state comes back
-- equal to its pre-draw value, never a hard-coded default.
-- The empty scene draws nothing, so canvas, shader, blend, depth, and color
-- are the states the renderer actually dirtied here; the wireframe/cull
-- restore is exercised in the failing-draw test, where the wireframe pass
-- dirties them before the injected failure.
function T.draw_restores_exact_caller_state()
  local canvas, shader = {}, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = false,
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

-- libs/engine must not import a game-level config, so the game's background
-- color is injected as opts.clearColor rather than hardcoded: the renderer
-- clears the scene canvas to exactly the table it was given, and falls back
-- to its own default when the caller (e.g. a test uninterested in
-- background color) omits it.
function T.draw_clears_the_scene_canvas_to_the_injected_color()
  local lg = fakeGraphics()
  local injected = { 0.5, 0.6, 0.7, 1 }
  local renderer = MapRenderer.new({ graphics = lg, clearColor = injected })
  local scene = emptySceneCamera()
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  Assert.equal(lg.calls.clear[1], injected, "scene canvas clears to the injected color")
end

function T.draw_without_an_injected_color_uses_a_renderer_default()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  Assert.isTrue(lg.calls.clear[1] ~= nil, "scene canvas still clears when no color is injected")
end

-- A draw failure must not leak the scene's state either: the wireframe item
-- dirties cull mode and wireframe before the injected draw failure, so the
-- captured caller state (including those two) is restored exactly and the
-- original draw error is rethrown.
function T.draw_failure_restores_exact_state_and_rethrows()
  local canvas, shader = {}, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = false,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
    failOnDrawCall = 1,
  })
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local identity = Matrix4.identity()
  local err = Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, {
      {
        {
          mesh = { setTexture = function() end },
          alphaClass = "wireframe",
          cullMode = "none",
          lightMask = 0,
          transform = identity,
          modelNormal = Matrix3.identity(),
          center = { 0, 0, 0 },
        },
      },
    }, FieldViewport.new(640, 480, { mode = "strict" }))
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  assertRestoredState(lg, canvas, shader)
  renderer:release()
  assertResourcesReleased(lg)
end

-- Construction is transactional: when the second shader fails, the first
-- must be released and the failure must reach the caller.
function T.new_releases_first_shader_when_second_shader_fails()
  local lg = fakeGraphics({ failOnNewShader = 2 })
  local err = Assert.throws(function()
    MapRenderer.new({ graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected shader failure", 1, true) ~= nil, "rethrows the shader failure")
  Assert.equal(#lg.shaders, 1, "only the first shader was created")
  Assert.equal(lg.shaders[1].releaseCount, 1, "the first shader is released when the second fails")
end

-- A failure while creating the very first shader creates nothing to leak and
-- still reaches the caller.
function T.new_first_shader_failure_leaks_nothing()
  local lg = fakeGraphics({ failOnNewShader = 1 })
  local err = Assert.throws(function()
    MapRenderer.new({ graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected shader failure", 1, true) ~= nil, "rethrows the shader failure")
  Assert.equal(#lg.shaders, 0, "no shader was created")
end

-- The renderer builds its shaders from the injected source reader -- the
-- engine-resource boundary -- never from host paths: the reader is called
-- with exactly the engine-owned shader paths, in construction order, and each
-- newShader receives that path's source.
function T.new_reads_shader_sources_through_the_injected_reader()
  local lg = fakeGraphics()
  local calls = {}
  local renderer = MapRenderer.new({
    graphics = lg,
    readSource = function(path)
      calls[#calls + 1] = path
      return "source:" .. path
    end,
  })
  Assert.deepEqual(calls, {
    "libs/engine/src/shaders/map.glsl",
    "libs/engine/src/shaders/edge.glsl",
  })
  Assert.equal(lg.shaders[1].source, "source:libs/engine/src/shaders/map.glsl")
  Assert.equal(lg.shaders[2].source, "source:libs/engine/src/shaders/edge.glsl")
  renderer:release()
end

-- Without an injected reader, the default resolves the engine shader paths in
-- the actual runtime environments: through love.filesystem from the packaged
-- archive, or -- in the repo checkout where the app runs as `love game/` and
-- the engine tree sits outside the source mount -- from the host file under
-- the LÖVE source base directory. Both real sources must reach newShader.
function T.new_reads_real_shader_sources_by_default()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  Assert.isTrue(lg.shaders[1].source:find("uniform", 1, true) ~= nil, "map shader source is real GLSL")
  Assert.isTrue(lg.shaders[2].source:find("uniform", 1, true) ~= nil, "edge shader source is real GLSL")
  renderer:release()
end

-- A source-read failure is a construction failure like any other: when the
-- reader fails for the second shader, the first is released and the error
-- propagates (the transactional construction holds through the new boundary).
function T.new_second_shader_source_failure_releases_first_shader()
  local lg = fakeGraphics()
  local reads = 0
  local err = Assert.throws(function()
    MapRenderer.new({
      graphics = lg,
      readSource = function()
        reads = reads + 1
        if reads == 2 then
          error("injected read failure")
        end
        return "source"
      end,
    })
  end)
  Assert.isTrue(tostring(err):find("injected read failure", 1, true) ~= nil, "rethrows the read failure")
  Assert.equal(#lg.shaders, 1, "only the first shader was created")
  Assert.equal(lg.shaders[1].releaseCount, 1, "the first shader is released when the second source read fails")
end

-- The very first source read failing creates nothing and still reaches the
-- caller.
function T.new_first_shader_source_failure_leaks_nothing()
  local lg = fakeGraphics()
  local err = Assert.throws(function()
    MapRenderer.new({
      graphics = lg,
      readSource = function()
        error("injected read failure")
      end,
    })
  end)
  Assert.isTrue(tostring(err):find("injected read failure", 1, true) ~= nil, "rethrows the read failure")
  Assert.equal(#lg.shaders, 0, "no shader was created")
end

-- opts.rasterScale (Story 1/14) makes the renderer allocate its targets at
-- the derived raster size, not the raw display viewport, and nearest-filter
-- the composited scene the same way idDepth already is -- the world stays
-- DS-relative while the final draw upscales it to the display viewport.
function T.new_with_raster_scale_derives_canvas_size_and_nearest_filters_scene_color()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg, rasterScale = 2 })
  local scene = emptySceneCamera()
  local viewport = { worldViewport = { x = 0, y = 0, width = 1280, height = 720 } }
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.equal(renderer.canvasW, 683, "the raster target width is derived from scale, not the display viewport")
  Assert.equal(renderer.canvasH, 384, "the raster target height is derived from scale, not the display viewport")
  local sceneColor = renderer.sceneColor --[[@as any]]
  Assert.deepEqual(
    sceneColor.filter,
    { "nearest", "nearest" },
    "the composited scene canvas is nearest-filtered like idDepth"
  )
  renderer:release()
end

-- setRasterScale is the seam the eventual in-game setting uses: it changes
-- which derived size the next draw allocates, and target recreation is
-- change-driven -- it fires only when the derived raster dimensions actually
-- differ, never merely because the method was called or the host resized at
-- an unchanged aspect/scale.
function T.setRasterScale_recreates_targets_only_when_derived_size_changes()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local viewport = { worldViewport = { x = 0, y = 0, width = 640, height = 480 } }

  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.equal(renderer.canvasW, 640, "nil scale renders at unrestricted host resolution")
  Assert.equal(renderer.canvasH, 480)

  renderer:setRasterScale(2)
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  local targets = renderer._sceneTargets
  Assert.equal(renderer.canvasW, 512, "raster scale 2 derives 512x384 from a 640x480 display viewport")
  Assert.equal(renderer.canvasH, 384)

  -- Redrawing at the same scale and display size must not recreate targets.
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.equal(renderer._sceneTargets, targets, "unchanged derived size reuses the target descriptor")

  -- A same-aspect host resize that derives the same raster size must also
  -- reuse the targets, not recreate them off the raw display dimensions.
  local widerSameAspect = { worldViewport = { x = 0, y = 0, width = 960, height = 720 } }
  renderer:draw(scene.runtime, scene.camera, nil, widerSameAspect)
  Assert.equal(renderer.canvasW, 512, "960x720 at scale 2 derives the same 512x384 raster as 640x480")
  Assert.equal(renderer.canvasH, 384)
  Assert.equal(renderer._sceneTargets, targets, "same derived raster size reuses the target descriptor")

  renderer:setRasterScale(nil)
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.isTrue(renderer._sceneTargets ~= targets, "changing the derived size recreates the target descriptor")
  Assert.equal(renderer.canvasW, 640, "nil scale again renders at unrestricted host resolution")
  Assert.equal(renderer.canvasH, 480)

  renderer:release()
end

-- Target reallocation builds the full replacement set before releasing the
-- live one: when any new-canvas allocation fails, every partial new canvas is
-- released, the previous targets and their recorded size survive, and the
-- failure reaches the caller. Each failOnNewCanvas value places the failure at
-- a different point in the new set (4 = first, 5 = second, 6 = third).
function T.canvas_recreation_failure_releases_partial_new_canvases()
  for _, failOnNewCanvas in ipairs({ 4, 5, 6 }) do
    local lg = fakeGraphics({ failOnNewCanvas = failOnNewCanvas })
    local renderer = MapRenderer.new({ graphics = lg })
    local scene = emptySceneCamera()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
    local oldW, oldH = renderer.canvasW, renderer.canvasH
    local oldTargets = renderer._sceneTargets
    Assert.equal(#lg.canvases, 3, "the first target set was created")

    local err = Assert.throws(function()
      renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(1280, 720, { mode = "expanded" }))
    end)
    Assert.isTrue(tostring(err):find("injected canvas failure", 1, true) ~= nil, "rethrows the canvas failure")

    for i = 4, #lg.canvases do
      Assert.equal(lg.canvases[i].releaseCount, 1, "partial canvas " .. i .. " was released")
    end
    -- The previous target set survives untouched, at its recorded size.
    Assert.equal(renderer.sceneColor, lg.canvases[1], "the previous scene canvas survives")
    Assert.equal(renderer.idDepth, lg.canvases[2], "the previous id-depth canvas survives")
    Assert.equal(renderer.depth, lg.canvases[3], "the previous depth canvas survives")
    Assert.equal(renderer.canvasW, oldW, "the recorded size survives")
    Assert.equal(renderer.canvasH, oldH, "the recorded size survives")
    Assert.equal(renderer._sceneTargets, oldTargets, "the previous target descriptor survives")
    Assert.equal(lg.canvases[1].releaseCount, 0, "the previous scene canvas is still owned")
    Assert.equal(lg.canvases[2].releaseCount, 0, "the previous id-depth canvas is still owned")
    Assert.equal(lg.canvases[3].releaseCount, 0, "the previous depth canvas is still owned")

    renderer:release()
    for _, canvas in ipairs(lg.canvases) do
      Assert.equal(canvas.releaseCount, 1, "release cleans up every canvas exactly once")
    end
  end
end

-- Edge configuration is part of target staging: a failure after the new ID
-- texture was sent but before all size uniforms were accepted restores the
-- previous uniforms, retains the previous published descriptor and canvases,
-- and releases the unpublished replacement set.
function T.canvas_recreation_send_failure_retains_previous_targets()
  local lg = fakeGraphics({ failOnEdgeShaderSend = 7 })
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local oldViewport = FieldViewport.new(640, 480, { mode = "strict" })
  renderer:draw(scene.runtime, scene.camera, nil, oldViewport)
  local oldTargets = assert(renderer._sceneTargets)
  local edgeShader = assert(lg.shaders[2])

  local err = Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(1280, 720, { mode = "expanded" }))
  end)
  Assert.isTrue(tostring(err):find("injected edge shader send failure", 1, true) ~= nil, "rethrows send failure")

  Assert.equal(renderer._sceneTargets, oldTargets, "the previous descriptor remains published")
  Assert.equal(renderer.sceneColor, lg.canvases[1], "the previous scene canvas survives")
  Assert.equal(renderer.idDepth, lg.canvases[2], "the previous ID canvas survives")
  Assert.equal(renderer.depth, lg.canvases[3], "the previous depth canvas survives")
  Assert.equal(renderer.canvasW, 640)
  Assert.equal(renderer.canvasH, 480)
  Assert.equal(edgeShader.uniforms.u_idTex, lg.canvases[2], "the previous ID texture binding is restored")
  Assert.deepEqual(edgeShader.uniforms.u_texelSize, { 1 / 640, 1 / 480 }, "the previous texel size is restored")
  Assert.equal(edgeShader.uniforms.u_edgeRadius, MapRenderer.fieldEdgeRadiusPixels(480))
  for i = 1, 3 do
    Assert.equal(lg.canvases[i].releaseCount, 0, "the previous canvas remains owned")
    Assert.equal(lg.canvases[i + 3].releaseCount, 1, "the unpublished replacement canvas is released")
  end

  renderer:draw(scene.runtime, scene.camera, nil, oldViewport)
  Assert.equal(#lg.canvases, 6, "the retained target set remains usable without allocation")
  renderer:release()
  for _, canvas in ipairs(lg.canvases) do
    Assert.equal(canvas.releaseCount, 1, "release cleans up every canvas exactly once")
  end
end

-- Renderer-owned frame storage is stable while its contents reset. The scene
-- target descriptor and edge size uniforms change only with target
-- generation. Releasing the canvases clears the descriptor so it cannot
-- retain released targets.
function T.draw_reuses_frame_storage_and_configures_edges_at_change_boundaries()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local stats = renderer.stats
  local edgeShader = renderer.edgeShader

  -- Edge colors are scene state, not a value the constructor sends
  -- before any scene exists.
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 0, "construction sends no scene-derived edge colors")

  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  local targets = assert(renderer._sceneTargets, "successful canvas creation publishes its target descriptor")
  Assert.equal(targets[1], renderer.sceneColor)
  Assert.equal(targets[2], renderer.idDepth)
  Assert.equal(targets.depthstencil, renderer.depth)
  Assert.equal(renderer.stats, stats, "draw reuses the public stats table")
  Assert.equal(shaderSendCount(edgeShader, "u_idTex"), 1)
  Assert.equal(shaderSendCount(edgeShader, "u_texelSize"), 1)
  Assert.equal(shaderSendCount(edgeShader, "u_edgeRadius"), 1)
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 1, "the first draw establishes the scene edge table")

  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.equal(renderer._sceneTargets, targets, "unchanged dimensions reuse the descriptor")
  Assert.equal(renderer.stats, stats, "later draws retain stats identity")
  Assert.equal(shaderSendCount(edgeShader, "u_idTex"), 1, "unchanged targets do not resend their texture")
  Assert.equal(shaderSendCount(edgeShader, "u_texelSize"), 1, "unchanged size does not resend texel size")
  Assert.equal(shaderSendCount(edgeShader, "u_edgeRadius"), 1, "unchanged size does not resend edge radius")
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 1, "the same edge table reference is not resent")

  viewport:resize(1280, 720)
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.isTrue(renderer._sceneTargets ~= targets, "replacement publishes a new target descriptor")
  Assert.equal(shaderSendCount(edgeShader, "u_idTex"), 2)
  Assert.equal(shaderSendCount(edgeShader, "u_texelSize"), 2)
  Assert.equal(shaderSendCount(edgeShader, "u_edgeRadius"), 2)
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 1, "a target resize alone does not resend the edge table")

  -- A different edge table (a new area's scene profile) resends, even though
  -- the raster size and target descriptor are unchanged.
  scene.runtime.edgeColors = edgeColorsFixture()
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 2, "a changed edge table resends")

  -- The DS composites edge color by RGB replacement, not an
  -- alpha-mix scalar; the fidelity path carries no alpha uniform to blend
  -- with.
  Assert.equal(shaderSendCount(edgeShader, "u_edgeAlpha"), 0, "no alpha-mix uniform exists on the fidelity path")

  renderer:release()
  Assert.isNil(renderer._sceneTargets, "release clears the target descriptor")
end

-- The decoded values MapRenderer sends for u_edgeColors are the
-- exact RGB555 decode of the scene's edge table, in table order -- not a
-- placeholder grey and not the wrong index/channel.
function T.draw_sends_the_scene_edge_table_decoded_to_normalized_rgb()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local edgeShader = renderer.edgeShader --[[@as any]]

  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  local sent
  for _, send in ipairs(edgeShader.sends) do
    if send.name == "u_edgeColors" then
      sent = send.values
    end
  end
  assert(sent, "u_edgeColors was sent")
  local fixture = edgeColorsFixture()
  for i = 0, 7 do
    Assert.deepEqual(sent[i + 1], decodeRgb555Float(fixture[i]), "edge color entry " .. i)
  end
  renderer:release()
end

-- A scene with no edge-color table is a required production collaborator
-- gone missing (every compiled HGSS field scene carries one -- field edge
-- marking is unconditionally enabled), not a case MapRenderer papers over
-- with an invented default.
function T.draw_requires_the_scenes_edge_color_table()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.runtime.edgeColors = nil

  Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  end)
  renderer:release()
end

-- After a failed recreation the renderer stays usable at the previous size,
-- and a later successful recreation swaps in a full new set while releasing
-- the previous set exactly once.
function T.canvas_recreation_failure_keeps_renderer_usable()
  local lg = fakeGraphics({ failOnNewCanvas = 5 })
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  local oldW, oldH = renderer.canvasW, renderer.canvasH

  Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(1280, 720, { mode = "expanded" }))
  end)

  -- Drawing at the retained size allocates nothing and still renders.
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  Assert.equal(#lg.canvases, 4, "the old-size draw reuses the retained canvases")
  Assert.equal(renderer.canvasW, oldW)
  Assert.equal(renderer.canvasH, oldH)

  -- The next successful recreation replaces the previous set, releasing it
  -- exactly once, and the renderer owns the new set.
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(1280, 720, { mode = "expanded" }))
  Assert.equal(#lg.canvases, 7, "a full new set was created")
  Assert.equal(lg.canvases[1].releaseCount, 1, "the old scene canvas is released exactly once")
  Assert.equal(lg.canvases[2].releaseCount, 1, "the old id-depth canvas is released exactly once")
  Assert.equal(lg.canvases[3].releaseCount, 1, "the old depth canvas is released exactly once")
  Assert.equal(lg.canvases[5].releaseCount, 0, "the new scene canvas is owned by the renderer")
  Assert.equal(lg.canvases[7].releaseCount, 0, "the new depth canvas is owned by the renderer")

  renderer:release()
  for _, canvas in ipairs(lg.canvases) do
    Assert.equal(canvas.releaseCount, 1, "release cleans up every canvas exactly once")
  end
end

-- The renderer draws exactly the ordered world parts it is given; it never
-- reads scene draws out of the runtime itself. Its queue scratch and every
-- pass array retain identity across frames, while a smaller later frame does
-- not draw stale items retained from an earlier build.
function T.draw_renders_only_given_parts_into_persistent_scratch()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local identity = Matrix4.identity()
  local function drawItem(id)
    return {
      id = id,
      mesh = { setTexture = function() end },
      material = { alphaClass = "opaque" },
      transform = identity,
      modelNormal = Matrix3.identity(),
      alphaClass = "opaque",
      cullMode = "back",
      polygonAlpha = 1.0,
      polygonMode = "modulation",
      polygonId = 0,
      lightMask = 0,
      center = { 0, 0, 0 },
    }
  end
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  scene.runtime.mapDraws = { drawItem("map") }
  scene.runtime.buildingDraws = { drawItem("building") }

  -- Every draw() also issues its own composite blit, so the empty frame's
  -- call count is the per-frame composite baseline: empty parts draw nothing
  -- beyond it, and each item in the given parts adds exactly one call.
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  local emptyFrame = lg.getDrawCalls()
  renderer:draw(scene.runtime, scene.camera, {
    { drawItem("a") },
    { drawItem("b") },
  }, viewport)
  local itemFrame = lg.getDrawCalls() - emptyFrame
  Assert.equal(itemFrame - emptyFrame, 2, "each given world item is drawn exactly once")

  local scratch = renderer._queueScratch
  Assert.isTrue(type(scratch) == "table", "the renderer owns queue scratch")
  local opaque = scratch.opaque
  local cutout = scratch.cutout
  local translucent = scratch.translucent
  local wireframe = scratch.wireframe
  local entries = scratch.translucentEntries

  renderer:draw(scene.runtime, scene.camera, { { drawItem("next") } }, viewport)
  Assert.equal(renderer.stats.drawCalls, 1, "a smaller frame retains no stale draw items")
  Assert.isTrue(renderer._queueScratch == scratch)
  Assert.isTrue(scratch.opaque == opaque)
  Assert.isTrue(scratch.cutout == cutout)
  Assert.isTrue(scratch.translucent == translucent)
  Assert.isTrue(scratch.wireframe == wireframe)
  Assert.isTrue(scratch.translucentEntries == entries)

  renderer:release()
end

-- Per-polygon light-mask encoding: one vec4 of 0/1 floats, bit i = light i
-- of the polygon's 4-bit mask. Different masks decode to different uniforms
-- and mask 0 to all-off.
function T.light_mask_uniforms_decode_polygon_bits()
  Assert.deepEqual(MapRenderer.lightMaskUniforms(0), { 0, 0, 0, 0 })
  Assert.deepEqual(MapRenderer.lightMaskUniforms(1), { 1, 0, 0, 0 })
  Assert.deepEqual(MapRenderer.lightMaskUniforms(2), { 0, 1, 0, 0 })
  Assert.deepEqual(MapRenderer.lightMaskUniforms(5), { 1, 0, 1, 0 })
  Assert.deepEqual(MapRenderer.lightMaskUniforms(15), { 1, 1, 1, 1 })
  -- Masks outside the 4-bit polygon field are malformed data.
  Assert.throws(function()
    MapRenderer.lightMaskUniforms(16)
  end)
  Assert.throws(function()
    MapRenderer.lightMaskUniforms(-1)
  end)
end

function T.light_mask_uniforms_returns_caller_owned_values()
  local exposed = MapRenderer.lightMaskUniforms(5)
  exposed[1], exposed[3] = 0, 0

  Assert.deepEqual(MapRenderer.lightMaskUniforms(5), { 1, 0, 1, 0 }, "callers cannot mutate the cached lookup")
end

local function lightingRecord(startHalfSeconds, diffuseRgb555, vectorX)
  local lights = {}
  for i = 1, 4 do
    lights[i] = {
      enabled = i == 1,
      colorRgb555 = diffuseRgb555,
      vectorFx12 = { vectorX, 0, -4096 },
    }
  end
  return {
    startHalfSeconds = startHalfSeconds,
    lights = lights,
    diffuseRgb555 = diffuseRgb555,
    ambientRgb555 = diffuseRgb555,
    specularRgb555 = diffuseRgb555,
    emissionRgb555 = diffuseRgb555,
  }
end

-- Lighting uniforms are change-driven by both profile and selected-record
-- identity. Decoded material arrays retain identity while their values track
-- record changes, and a lit/unlit transition clears the profile exactly once.
function T.lighting_cache_tracks_profile_record_and_unlit_transitions()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local shader = lg.shaders[1]
  local red, green = 31, 31 * 32
  local morning = lightingRecord(0, red, 0)
  local evening = lightingRecord(10, green, 4096)
  local profile = { records = { morning, evening } }
  local runtime = { lighting = profile, fieldTimeSeconds = 0 }

  renderer:_sendLighting(runtime)
  Assert.equal(#shader.sends, 12, "first lit record sends four light uniform groups")
  local colors = renderer._lightMaterialColors
  local diffuse = colors.diffuse
  Assert.deepEqual(diffuse, { 1, 0, 0 })

  renderer:_sendLighting(runtime)
  Assert.equal(#shader.sends, 12, "same profile and record sends nothing")
  Assert.equal(renderer._lightMaterialColors, colors)
  Assert.equal(renderer._lightMaterialColors.diffuse, diffuse)

  runtime.fieldTimeSeconds = 20
  renderer:_sendLighting(runtime)
  Assert.equal(#shader.sends, 24, "time selection moving records resends lighting")
  Assert.equal(renderer._lightMaterialColors, colors, "decoded material storage is persistent")
  Assert.equal(renderer._lightMaterialColors.diffuse, diffuse)
  Assert.deepEqual(diffuse, { 0, 1, 0 })

  runtime.lighting = { records = { evening } }
  renderer:_sendLighting(runtime)
  Assert.equal(#shader.sends, 36, "profile identity participates in the cache key")

  runtime.lighting = nil
  renderer:_sendLighting(runtime)
  Assert.equal(#shader.sends, 48, "lit to unlit clears every light uniform once")
  Assert.isNil(renderer._lightMaterialColors, "unlit scenes expose no profile material colors")
  renderer:_sendLighting(runtime)
  Assert.equal(#shader.sends, 48, "stable unlit state sends nothing")

  runtime.lighting = profile
  runtime.fieldTimeSeconds = 0
  renderer:_sendLighting(runtime)
  Assert.equal(#shader.sends, 60, "unlit to lit restores the selected record")
  Assert.equal(renderer._lightMaterialColors, colors)
  Assert.deepEqual(renderer._lightMaterialColors.diffuse, { 1, 0, 0 })
  renderer:release()
end

local function passItem(alphaClass, z, opts)
  opts = opts or {}
  return {
    mesh = { setTexture = function() end },
    material = { texMatrix = Matrix4.identity() },
    transform = Matrix4.identity(),
    modelNormal = Matrix3.identity(),
    alphaClass = alphaClass,
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0, 0, z },
    depthEqual = opts.depthEqual or false,
    translucentDepthWrite = opts.translucentDepthWrite or false,
  }
end

-- The opaque polygon-ID field survives translucent drawing rather
-- than being replaced by an invented sentinel (melonDS: the ID/depth
-- attribute the edge pass reads is not one value overloaded to also mean
-- "translucent"). A translucent item's own polygon ID is a distinct,
-- independent attribute -- it must send exactly the same
-- polygonId/REAR_PLANE_ID normalization every opaque/cutout item sends, never
-- a value carved out of the polygon-ID domain to signal translucency.
function T.translucent_draws_send_their_own_polygon_id_not_an_invented_sentinel()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local item = passItem("translucent", -1)
  item.polygonId = 7

  renderer:draw(scene.runtime, scene.camera, { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))

  local sent
  for _, send in ipairs(lg.shaders[1].sends) do
    if send.name == "u_polygonId" then
      sent = send.values[1]
    end
  end
  Assert.equal(
    sent,
    item.polygonId / MapRenderer.REAR_PLANE_ID,
    "translucent items send their real polygon id, never a sentinel outside the item's own attributes"
  )
  renderer:release()
end

function T.billboard_draw_sends_change_driven_data_for_nonuniform_scale()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local viewMatrix = Matrix4.multiply(Matrix4.rotateX(0.37), Matrix4.rotateY(-0.61))
  scene.camera.view = function()
    return viewMatrix
  end
  local item = passItem("opaque", 0)
  item.billboardBase = Matrix4.multiply(Matrix4.rotateZ(0.7), Matrix4.scale(2, 3, 4))
  item.transform = item.billboardBase
  item.billboardCenter, item.billboardScale = BillboardTransform.components(item.billboardBase)
  local originalTransform = item.transform

  renderer:draw(scene.runtime, scene.camera, { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))

  local sentCenter, sentScale, sentModel
  for _, send in ipairs(lg.shaders[1].sends) do
    if send.name == "u_billboardCenter" then
      sentCenter = send.values[1]
    elseif send.name == "u_billboardScale" then
      sentScale = send.values[1]
    elseif send.name == "u_model" then
      sentModel = send.values[2]
    end
  end
  Assert.equal(sentCenter, item.billboardCenter)
  Assert.equal(sentScale, item.billboardScale)
  Assert.isNil(sentModel, "ordinary billboard draws do not bind a camera-facing model matrix")
  Assert.equal(item.transform, originalTransform, "billboard drawing does not mutate the item")
  renderer:release()
end

function T.ordinary_draw_sends_the_items_precomputed_model_normal()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local item = passItem("opaque", 0)
  item.modelNormal = { 0.5, 0, 0, 0, 1 / 3, 0, 0, 0, 0.25 }

  renderer:_drawItem(item, Matrix4.identity(), "opaque")

  local sent
  for _, send in ipairs(lg.shaders[1].sends) do
    if send.name == "u_modelNormal" then
      sent = send.values[2]
    end
  end
  Assert.equal(sent, item.modelNormal, "ordinary draws send the precomputed item field without rebuilding it")
  renderer:release()
end

function T.ordinary_draw_requires_an_explicit_model_normal()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local item = passItem("opaque", 0)
  item.modelNormal = nil

  Assert.throws(function()
    renderer:_drawItem(item, Matrix4.identity(), "opaque")
  end)
  renderer:release()
end

-- Pass-invariant state is established once. Translucent depth mode changes
-- only when its write toggle changes in sorted order.
--
-- The corpus census found zero HGSS field materials resolving depth-equal
-- (see tests/rom/specular_shininess_census_test.lua), and the compiler-time
-- rejection contract (libs/assets/tests/polygon_state_test.lua) means a
-- compiled item can never carry depthEqual = true. The translucent pass
-- itself always compares "less", regardless of an item's depthEqual field (a
-- defensive item here still sets it, to prove the renderer no longer
-- branches on it -- not merely that the compiler happens not to produce it).
-- Host `lequal` is retired, not merely unused.
function T.draw_sets_wireframe_and_translucent_state_once_per_run()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local items = {
    passItem("translucent", -4),
    passItem("translucent", -3),
    passItem("translucent", -2, { depthEqual = true }),
    passItem("translucent", -1, { depthEqual = true, translucentDepthWrite = true }),
    passItem("wireframe", 0),
    passItem("wireframe", 1),
  }

  renderer:draw(scene.runtime, scene.camera, { items }, FieldViewport.new(640, 480, { mode = "strict" }))

  -- The translucent RGB blend switch itself is a separate compositor-
  -- architecture decision (see the implementation notes); this test only
  -- pins depth-equal's retirement.
  Assert.equal(callCount(lg.calls.blend, { mode = "alpha", alpha = "alphamultiply" }), 1)
  Assert.equal(callCount(lg.calls.depth, { mode = "less", write = false }), 1)
  Assert.equal(
    callCount(lg.calls.depth, { mode = "less", write = true }),
    3,
    "translucent write-on, filled, and wireframe passes"
  )
  Assert.equal(callCount(lg.calls.depth, { mode = "lequal", write = false }), 0, "lequal is retired, not merely unused")
  Assert.equal(callCount(lg.calls.depth, { mode = "lequal", write = true }), 0, "lequal is retired, not merely unused")
  local wireframeEnables = 0
  for _, enabled in ipairs(lg.calls.wireframe) do
    if enabled then
      wireframeEnables = wireframeEnables + 1
    end
  end
  Assert.equal(wireframeEnables, 1, "wireframe mode is enabled once for the pass")
  renderer:release()
end

-- The DS geometry engine submits each vertex under the then-current matrix;
-- the bend bake must move only the first `leading` vertices under the
-- straddle transform and leave the rest under the item transform, with every
-- non-position attribute untouched.
function T.straddle_bake_translates_only_the_leading_vertices()
  local source = stripVertices()
  local baked = MapRenderer.bakeStraddle(source, 2, Matrix4.translate(10, 0, 0), Matrix4.identity())

  Assert.equal(#baked, 6)
  -- Leading vertices move +10 in x; trailing vertices stay put.
  Assert.near(baked[1][1], 9, 1e-9)
  Assert.near(baked[2][1], 11, 1e-9)
  Assert.near(baked[3][1], 1, 1e-9)
  Assert.near(baked[4][1], -1, 1e-9)
  Assert.near(baked[5][1], -1, 1e-9)
  Assert.near(baked[6][1], 1, 1e-9)
  -- y/z, uv, normal, color, and color source ride unchanged on both halves.
  for i, v in ipairs(baked) do
    local s = source[i]
    Assert.near(v[2], s[2], 1e-9, "y untouched")
    Assert.near(v[3], s[3], 1e-9, "z untouched")
    Assert.near(v[6], s[6], 1e-9, "normal x untouched")
    Assert.near(v[7], s[7], 1e-9, "normal y untouched")
    Assert.near(v[8], s[8], 1e-9, "normal z untouched")
    Assert.equal(v[13], 0, "color source untouched")
  end
  Assert.equal(baked[1][4], 0, "u untouched")
  Assert.equal(baked[1][5], 1, "v untouched")
  Assert.equal(baked[1][9], 1, "color untouched")
end

-- Normals bend with their half's matrix (the linear part only), so the
-- shader lights the straddled half under the matrix it was submitted under.
function T.straddle_bake_rotates_the_leading_normals_with_the_straddle_matrix()
  local baked = MapRenderer.bakeStraddle(stripVertices(), 1, Matrix4.rotateY(math.pi / 2), Matrix4.identity())

  -- rotateY(pi/2) maps +z to +x: the leading normal follows the matrix.
  Assert.near(baked[1][6], 1, 1e-9)
  Assert.near(baked[1][7], 0, 1e-9)
  Assert.near(baked[1][8], 0, 1e-9)
  -- Trailing vertices keep their own normal (identity linear part).
  Assert.near(baked[2][6], 0, 1e-9)
  Assert.near(baked[2][7], 0, 1e-9)
  Assert.near(baked[2][8], 1, 1e-9)
end

-- A straddle record always splits a segment strictly between 0 and its full
-- vertex count; anything else is a corrupted provenance record and fails
-- loudly instead of baking a degenerate bend.
function T.straddle_bake_rejects_a_leading_count_out_of_range()
  Assert.throws(function()
    MapRenderer.bakeStraddle(stripVertices(), 0, Matrix4.identity(), Matrix4.identity())
  end)
  Assert.throws(function()
    MapRenderer.bakeStraddle(stripVertices(), 7, Matrix4.identity(), Matrix4.identity())
  end)
end

-- ---- straddle scratch-mesh ownership (injected graphics, no love needed) ----

-- A fake graphics namespace with enough surface for the straddle draw path:
-- newShader returns silent shaders, newMesh records every scratch mesh and
-- its vertex map, and draw can be made to raise on demand. This is the
-- ownership boundary of the per-frame bake: the scratch is created and
-- released within one draw call -- on the failure path as well as the
-- success path -- and never touches the pool-shared source mesh.
local function straddleGraphics(opts)
  opts = opts or {}
  local meshes, shaders = {}, {}
  return {
    meshes = meshes,
    shaders = shaders,
    newShader = function()
      local shader = { sends = {} }
      shader.send = function(_, name, ...)
        shader.sends[#shader.sends + 1] = { name = name, values = { ... } }
      end
      shaders[#shaders + 1] = shader
      return shader
    end,
    newMesh = function(_, vertices, _, _)
      local scratch
      scratch = {
        vertices = vertices,
        vertexMap = nil,
        released = false,
        release = function()
          scratch.released = true
        end,
        setVertexMap = function(_, map)
          scratch.vertexMap = map
        end,
        setTexture = function() end,
      }
      meshes[#meshes + 1] = scratch
      return scratch
    end,
    setShader = function() end,
    setDepthMode = function() end,
    setBlendMode = function() end,
    setWireframe = function() end,
    setMeshCullMode = function() end,
    draw = function()
      if opts.failOnDraw then
        error("injected straddle draw failure")
      end
    end,
  }
end

-- A fake source mesh matching the love API shape the straddle path reads
-- (getVertex returns the 13 attribute components as multiple values).
local function sourceMesh()
  local vertices = {
    { -1, 0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 2, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 2, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
  }
  return {
    getVertexCount = function()
      return #vertices
    end,
    getVertex = function(_, i)
      return vertices[i][1],
        vertices[i][2],
        vertices[i][3],
        vertices[i][4],
        vertices[i][5],
        vertices[i][6],
        vertices[i][7],
        vertices[i][8],
        vertices[i][9],
        vertices[i][10],
        vertices[i][11],
        vertices[i][12],
        vertices[i][13]
    end,
    getVertexMap = function()
      return { 4, 3, 2, 1 }
    end,
    setTexture = function() end,
  }
end

local function straddleDrawItem(mesh)
  return {
    mesh = mesh,
    material = { alphaClass = "opaque" },
    transform = Matrix4.identity(),
    modelNormal = { 2, 0, 0, 0, 3, 0, 0, 0, 4 },
    alphaClass = "opaque",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 0,
    center = { 0, 0, 0 },
    straddle = { leading = 2, transform = Matrix4.translate(10, 0, 0) },
  }
end

function T.straddle_filled_and_wireframe_paths_send_identity_model_normal()
  local fake = straddleGraphics()
  local renderer = MapRenderer.new({ graphics = fake })
  local item = straddleDrawItem(sourceMesh())

  renderer:_drawStraddle(item, Matrix4.identity(), "opaque")
  renderer:_drawWireframeStraddle(item, Matrix4.identity(), "wireframe")

  local sent = {}
  for _, send in ipairs(fake.shaders[1].sends) do
    if send.name == "u_modelNormal" then
      sent[#sent + 1] = send.values[2]
    end
  end
  Assert.equal(#sent, 2, "both straddle shader paths send model-normal state")
  Assert.deepEqual(sent[1], Matrix3.identity(), "filled straddle normals are already world-baked")
  Assert.deepEqual(sent[2], Matrix3.identity(), "wireframe straddle normals are already world-baked")
end

function T.billboard_straddles_keep_the_cpu_fallback_for_the_scratch_bake()
  local fake = straddleGraphics()
  local renderer = MapRenderer.new({ graphics = fake })
  local item = straddleDrawItem(sourceMesh())
  item.billboardBase = Matrix4.multiply(Matrix4.translate(0, 0, -3), Matrix4.scale(2, 1, 1))
  item.transform = item.billboardBase
  item.billboardCenter, item.billboardScale = BillboardTransform.components(item.billboardBase)
  local viewMatrix = Matrix4.rotateY(math.pi / 2)

  renderer:_drawStraddle(item, Matrix4.identity(), "opaque", viewMatrix)

  local resolved = BillboardTransform.resolve(item.billboardBase, viewMatrix)
  local expectedX, expectedY, expectedZ = Matrix4.transformPoint(resolved, 1, 2, 0)
  local scratch = fake.meshes[1]
  Assert.near(scratch.vertices[3][1], expectedX, 1e-9)
  Assert.near(scratch.vertices[3][2], expectedY, 1e-9)
  Assert.near(scratch.vertices[3][3], expectedZ, 1e-9)
  Assert.isTrue(scratch.released, "the exceptional billboard scratch is still released")
end

-- The straddle draw bakes the shared mesh's vertices into a scratch mesh
-- that carries the source's vertex map, draws it, and releases it within
-- the call -- the shared pool mesh is never mutated.
function T.straddle_draw_bakes_into_a_released_scratch_with_the_source_map()
  local fake = straddleGraphics()
  local renderer = MapRenderer.new({ graphics = fake })
  local source = sourceMesh()
  local item = straddleDrawItem(source)

  renderer:_drawStraddle(item, Matrix4.identity())

  Assert.equal(#fake.meshes, 1)
  local scratch = fake.meshes[1]
  Assert.isTrue(scratch.released, "the scratch mesh is released after the draw")
  Assert.deepEqual(scratch.vertexMap, { 4, 3, 2, 1 }, "the scratch carries the source's vertex map")
  -- The bake moved the first `leading` vertices under the straddle
  -- transform and left the rest under the item transform.
  Assert.near(scratch.vertices[1][1], 9, 1e-9)
  Assert.near(scratch.vertices[2][1], 11, 1e-9)
  Assert.near(scratch.vertices[3][1], 1, 1e-9)
  Assert.near(scratch.vertices[4][1], -1, 1e-9)
end

-- A draw failure inside the straddle path must still release the scratch
-- mesh it already acquired, so a failed frame leaks no GPU object.
function T.a_failed_straddle_draw_still_releases_the_scratch()
  local fake = straddleGraphics({ failOnDraw = true })
  local renderer = MapRenderer.new({ graphics = fake })

  Assert.throws(function()
    renderer:_drawStraddle(straddleDrawItem(sourceMesh()), Matrix4.identity())
  end)

  Assert.equal(#fake.meshes, 1)
  Assert.isTrue(fake.meshes[1].released, "a failed straddle draw releases its scratch")
end

-- ---- wireframe straddle dispatch ----
--
-- The wireframe pass routes straddling items through the same per-vertex
-- bend as the filled passes (the corpus has one real straddle+wireframe
-- case: indoor:146:e8aca8e43479 in map 0080), so a wireframe straddle item
-- bakes its leading vertices under the straddle transform and releases the
-- scratch within the call. Pass-wide wireframe state is owned by draw().
function T.wireframe_straddle_bakes_into_a_released_scratch()
  local fake = straddleGraphics()
  local renderer = MapRenderer.new({ graphics = fake })
  local item = straddleDrawItem(sourceMesh())

  renderer:_drawWireframe(item, Matrix4.identity())

  Assert.equal(#fake.meshes, 1)
  local scratch = fake.meshes[1]
  Assert.isTrue(scratch.released, "the wireframe scratch is released after the draw")
  Assert.deepEqual(scratch.vertexMap, { 4, 3, 2, 1 }, "the wireframe scratch carries the source's vertex map")
  -- The bake moved the first `leading` vertices under the straddle
  -- transform and left the rest under the item transform.
  Assert.near(scratch.vertices[1][1], 9, 1e-9)
  Assert.near(scratch.vertices[2][1], 11, 1e-9)
  Assert.near(scratch.vertices[3][1], 1, 1e-9)
  Assert.near(scratch.vertices[4][1], -1, 1e-9)
end

-- A non-straddling wireframe item draws its own mesh directly, without
-- baking a scratch.
function T.wireframe_draw_without_a_straddle_uses_the_item_mesh()
  local fake = straddleGraphics()
  local renderer = MapRenderer.new({ graphics = fake })
  local item = straddleDrawItem(sourceMesh())
  item.straddle = nil

  renderer:_drawWireframe(item, Matrix4.identity())

  Assert.equal(#fake.meshes, 0, "no scratch is baked for a non-straddling wireframe item")
end

-- A draw failure inside the wireframe straddle path must still release the
-- scratch mesh it already acquired.
function T.a_failed_wireframe_straddle_draw_still_releases_the_scratch()
  local fake = straddleGraphics({ failOnDraw = true })
  local renderer = MapRenderer.new({ graphics = fake })

  Assert.throws(function()
    renderer:_drawWireframe(straddleDrawItem(sourceMesh()), Matrix4.identity())
  end)

  Assert.equal(#fake.meshes, 1)
  Assert.isTrue(fake.meshes[1].released, "a failed wireframe straddle draw releases its scratch")
end

return { tests = T }
