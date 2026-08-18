-- Pure MapRenderer contracts that need no graphics context: the per-draw
-- light-mask encoding, the straddle bend bake, and the scene-schema gate.
-- Everything that compiles a shader, allocates a render target, or reads
-- back driver state lives in map_renderer_graphics_test.lua. (The state
-- target's color-resolution sizing and the transactional rollback contract
-- are pinned by state_target_dimensions_equal_color_dimensions and
-- state_target_recreation_failure_releases_partials_and_keeps_previous_set
-- below, both driven through the fake graphics context.)

local Assert = require("tests.support.Assert")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local FieldViewport = require("libs.engine.src.FieldViewport")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local BillboardTransform = require("libs.engine.src.BillboardTransform")
local FieldActorDraw = require("libs.engine.src.FieldActorDraw")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local RenderQueue = require("libs.engine.src.RenderQueue")

local T = {}

-- Eight zero-based RGB555-packed edge colors, the shape
-- MapAssetCompiler now emits (HgssFieldEdgeColors.TABLE_A/TABLE_B) and
-- MapRenderer decodes at draw time -- distinct, arbitrary packed values so a
-- decode bug (wrong channel, wrong index) cannot hide behind a uniform grey
-- fixture.
local function edgeColorsFixture()
  return { [0] = 0, 1 + 2 * 32 + 3 * 1024, 4, 5 * 32, 6 * 1024, 7, 8 + 8 * 32, 9 }
end

-- A disabled fog fixture (HgssFieldFog.runtimePreset's shape for a disabled
-- weather): the default for tests not exercising fog wiring itself.
local function disabledFogFixture()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = 0
  end
  return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
end

-- The raw 5-bit RGB555 decode (each channel normalized /31, no six-bit
-- expansion): still the correct expected domain for material/light color
-- registers and, until a separate deliverable fixes it, the fog color this
-- file's fog-preset tests assert against -- MapRenderer's DsLighting-facing
-- and fog decode paths are out of this deliverable's scope.
local function decodeRgb555Float(packed)
  return {
    (packed % 32) / 31,
    (math.floor(packed / 32) % 32) / 31,
    (math.floor(packed / 1024) % 32) / 31,
  }
end

-- The exact decode MapRenderer must apply to a packed RGB555 edge-color
-- entry before it reaches the final shader: each 5-bit channel expanded to
-- the DS six-bit framebuffer domain (melonDS's rule -- 0 stays 0, any
-- non-zero n becomes 2n+1 -- the same expansion map.glsl's expand5to6
-- applies to texture/vertex colors), then normalized by 63, not 31. Edge
-- color composites directly into the six-bit scene RGB (edge.glsl replaces
-- scene.rgb outright), so a raw /31 RGB555 value is the wrong domain, not
-- merely an unrounded one. This is an independently hand-derived expected
-- function, not a copy of MapRenderer's private decoder.
local function expand5to6(c5)
  if c5 <= 0 then
    return 0
  end
  return c5 * 2 + 1
end

local function decodeRgb555ToRgb6Float(packed)
  local r = packed % 32
  local g = math.floor(packed / 32) % 32
  local b = math.floor(packed / 1024) % 32
  return {
    expand5to6(r) / 63,
    expand5to6(g) / 63,
    expand5to6(b) / 63,
  }
end

-- An empty scene and camera for the restoration-contract tests: the renderer
-- draws nothing but still binds/unbinds canvases, shaders, and state.
local function emptySceneCamera()
  local identity = Matrix4.identity()
  return {
    camera = {
      distance = 26,
      far = 400,
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
      -- Likewise fog: the resolved global weather preset, disabled by
      -- default here so tests unrelated to fog wiring do not need their own
      -- fixture.
      fog = disabledFogFixture(),
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
    clear = function(...)
      calls.clear[#calls.clear + 1] = { ... }
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
  Assert.equal(#lg.shaders, 3, "the three engine shaders were created (color, resolve, state)")
  Assert.equal(#lg.canvases, 4, "the sceneColor, colorDepth, renderState, and stateDepth canvases were created")
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

function T.rejects_stale_scene_schema()
  local ok, err = pcall(MapSceneLoader.load, nil, { schema = "g4-map-scene-v1" })
  Assert.isTrue(
    not ok and err.code == "MAP_SCENE_UNSUPPORTED_SCHEMA",
    "rejects old scene schema: " .. tostring(err.code)
  )
end

-- The fixed-192-line semantic raster is gone: state coverage is one-to-one
-- with color coverage, so the renderer's state dimensions equal the color
-- dimensions after any draw. The durable names carry the new meaning
-- (renderState/stateDepth/stateW/stateH/_stateTargets); on this baseline they
-- did not exist yet, so the pre-implementation red was the actual size
-- mismatch (341 vs 1280), not a nil-index crash.
function T.state_target_dimensions_equal_color_dimensions()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local viewport = { worldViewport = { x = 0, y = 0, width = 1280, height = 720 } }
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.equal(renderer.colorW, 1280)
  Assert.equal(renderer.colorH, 720)
  Assert.equal(renderer.stateW, renderer.colorW, "state width equals the color width, not a fixed semantic raster")
  Assert.equal(renderer.stateH, renderer.colorH, "state height equals the color height, not a fixed semantic raster")
  Assert.equal(renderer.stateW, 1280)
  Assert.equal(renderer.stateH, 720)
  renderer:release()
end

-- Target recreation is transactional at equal color/state dimensions: a
-- failure while building the replacement set leaves the previous targets and
-- their recorded size fully usable, and every partial new canvas is released.
-- The first draw allocates canvases 1-4; a failure on canvas 5 (the new
-- sceneColor) must keep the old set published.
function T.state_target_recreation_failure_releases_partials_and_keeps_previous_set()
  for _, failOnNewCanvas in ipairs({ 5, 6, 7, 8 }) do
    local lg = fakeGraphics({ failOnNewCanvas = failOnNewCanvas })
    local renderer = MapRenderer.new({ graphics = lg })
    local scene = emptySceneCamera()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
    local oldColorW, oldColorH, oldStateW, oldStateH =
      renderer.colorW, renderer.colorH, renderer.stateW, renderer.stateH
    local oldColorTargets, oldStateTargets = renderer._colorTargets, renderer._stateTargets
    Assert.equal(#lg.canvases, 4, "the first target set was created")

    local err = Assert.throws(function()
      renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(1280, 720, { mode = "expanded" }))
    end)
    Assert.isTrue(tostring(err):find("injected canvas failure", 1, true) ~= nil, "rethrows the canvas failure")

    for i = 5, #lg.canvases do
      Assert.equal(lg.canvases[i].releaseCount, 1, "partial canvas " .. i .. " was released")
    end
    Assert.equal(renderer.sceneColor, lg.canvases[1], "the previous scene canvas survives")
    Assert.equal(renderer.colorDepth, lg.canvases[2], "the previous color-depth canvas survives")
    Assert.equal(renderer.renderState, lg.canvases[3], "the previous state canvas survives")
    Assert.equal(renderer.stateDepth, lg.canvases[4], "the previous state-depth canvas survives")
    Assert.equal(renderer.colorW, oldColorW, "the recorded color size survives")
    Assert.equal(renderer.colorH, oldColorH, "the recorded color size survives")
    Assert.equal(renderer.stateW, oldStateW, "the recorded state width survives")
    Assert.equal(renderer.stateH, oldStateH, "the recorded state height survives")
    Assert.equal(renderer._colorTargets, oldColorTargets, "the previous color target descriptor survives")
    Assert.equal(renderer._stateTargets, oldStateTargets, "the previous state target descriptor survives")
    for i = 1, 4 do
      Assert.equal(lg.canvases[i].releaseCount, 0, "the previous canvas " .. i .. " is still owned")
    end

    renderer:release()
    for _, canvas in ipairs(lg.canvases) do
      Assert.equal(canvas.releaseCount, 1, "release cleans up every canvas exactly once")
    end
  end
end

-- The fixed-DS-density semantic-size helper is deleted, not left as a dead
-- compatibility wrapper: no production, test, or doc may still derive a
-- 192-line state raster from the display size.
function T.no_fixed_semantic_size_helper_remains()
  ---@diagnostic disable-next-line: undefined-field -- intentional: asserts the deleted helper is absent
  Assert.isNil(MapRenderer.semanticTargetSize, "the fixed-192 semantic-size helper is removed")
end

-- R02 renderer contract: the edge radius the renderer sends on the real draw
-- path is the nearest integer of the viewport's field-pixel scale
-- (referenceFrame.height / 192 * zoom), minimum 1. At 1280x720 expanded
-- (referenceFrame.height 720) with zoom 1, the scale is 720/192 = 3.75, so
-- the radius is floor(3.75 + 0.5) = 4; the same viewport at zoom 0.5 gives
-- floor(1.875 + 0.5) = 2; a 2560x1440 viewport at zoom 1 gives
-- floor(7.5 + 0.5) = 8; a 480p viewport at zoom 1 gives floor(2.5 + 0.5) = 3.
function T.draw_sends_the_rounded_field_pixel_scale_as_the_edge_radius()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local edgeShader = lg.shaders[2]

  local function radiusSentFor(viewport, zoom)
    scene.camera.zoom = zoom
    renderer:draw(scene.runtime, scene.camera, nil, viewport)
    local last
    for _, send in ipairs(edgeShader.sends) do
      if send.name == "u_edgeRadiusPx" then
        last = send.values[1]
      end
    end
    return last
  end

  Assert.equal(radiusSentFor(FieldViewport.new(1280, 720, { mode = "expanded" }), 1.0), 4, "radius 4 at 720p zoom 1")
  Assert.equal(radiusSentFor(FieldViewport.new(1280, 720, { mode = "expanded" }), 0.5), 2, "radius 2 at 720p zoom 0.5")
  Assert.equal(radiusSentFor(FieldViewport.new(2560, 1440, { mode = "expanded" }), 1.0), 8, "radius 8 at 1440p zoom 1")
  Assert.equal(radiusSentFor(FieldViewport.new(640, 480, { mode = "strict" }), 1.0), 3, "radius 3 at 480p zoom 1")
  renderer:release()
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
-- background color) omits it. The state pass clears first (its own
-- DS_STATE_CLEAR rear-plane value, not the scene color), so the color clear
-- is the draw's second clear call.
function T.draw_clears_the_scene_canvas_to_the_injected_color()
  local lg = fakeGraphics()
  local injected = { 0.5, 0.6, 0.7, 1 }
  local renderer = MapRenderer.new({ graphics = lg, clearColor = injected })
  local scene = emptySceneCamera()
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  Assert.equal(lg.calls.clear[2][1], injected, "scene canvas clears to the injected color")
end

function T.draw_without_an_injected_color_uses_a_renderer_default()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  Assert.isTrue(lg.calls.clear[2][1] ~= nil, "scene canvas still clears when no color is injected")
end

-- A draw failure must not leak the scene's state either: the wireframe item
-- dirties cull mode and wireframe before the injected draw failure, so the
-- captured caller state (including those two) is restored exactly and the
-- original draw error is rethrown. The item's first draw call is the
-- state pass's own wireframe pass (which never touches host wireframe/cull
-- state), so the failure is injected on the second draw call -- the color
-- pass's wireframe draw, issued after setWireframe(true)/setMeshCullMode.
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
    failOnDrawCall = 2,
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
          polygonId = 0,
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
    "libs/engine/src/shaders/state.glsl",
  })
  Assert.equal(lg.shaders[1].source, "source:libs/engine/src/shaders/map.glsl")
  Assert.equal(lg.shaders[2].source, "source:libs/engine/src/shaders/edge.glsl")
  Assert.equal(lg.shaders[3].source, "source:libs/engine/src/shaders/state.glsl")
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
  Assert.isTrue(lg.shaders[3].source:find("uniform", 1, true) ~= nil, "state shader source is real GLSL")
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

-- Color targets always match the display size directly; the render-state
-- targets share the exact same dimensions (state coverage is one-to-one with
-- color coverage -- there is no separate semantic-size derivation any more).
-- sceneColor and renderState are both nearest-filtered.
function T.new_derives_equal_color_and_state_target_sizes_and_nearest_filters_scene_color_and_render_state()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local viewport = { worldViewport = { x = 0, y = 0, width = 1280, height = 720 } }
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.equal(renderer.colorW, 1280, "the color target matches the display viewport width exactly")
  Assert.equal(renderer.colorH, 720, "the color target matches the display viewport height exactly")
  Assert.equal(renderer.stateW, 1280, "the state target matches the color target width exactly")
  Assert.equal(renderer.stateH, 720, "the state target matches the color target height exactly")
  local sceneColor = renderer.sceneColor --[[@as any]]
  local renderState = renderer.renderState --[[@as any]]
  Assert.deepEqual(sceneColor.filter, { "nearest", "nearest" }, "sceneColor is nearest-filtered")
  Assert.deepEqual(renderState.filter, { "nearest", "nearest" }, "renderState is nearest-filtered")
  renderer:release()
end

-- Target reallocation builds the full replacement set before releasing the
-- live one: when any new-canvas allocation fails, every partial new canvas is
-- released, the previous targets and their recorded size survive, and the
-- failure reaches the caller. Each failOnNewCanvas value places the failure at
-- a different point in the new set of four (sceneColor, colorDepth,
-- renderState, stateDepth), which the first draw allocates as canvases 1-4.
function T.canvas_recreation_failure_releases_partial_new_canvases()
  for _, failOnNewCanvas in ipairs({ 5, 6, 7, 8 }) do
    local lg = fakeGraphics({ failOnNewCanvas = failOnNewCanvas })
    local renderer = MapRenderer.new({ graphics = lg })
    local scene = emptySceneCamera()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
    local oldColorW, oldColorH, oldStateW, oldStateH =
      renderer.colorW, renderer.colorH, renderer.stateW, renderer.stateH
    local oldColorTargets, oldStateTargets = renderer._colorTargets, renderer._stateTargets
    Assert.equal(#lg.canvases, 4, "the first target set was created")

    local err = Assert.throws(function()
      renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(1280, 720, { mode = "expanded" }))
    end)
    Assert.isTrue(tostring(err):find("injected canvas failure", 1, true) ~= nil, "rethrows the canvas failure")

    for i = 5, #lg.canvases do
      Assert.equal(lg.canvases[i].releaseCount, 1, "partial canvas " .. i .. " was released")
    end
    -- The previous target set survives untouched, at its recorded size.
    Assert.equal(renderer.sceneColor, lg.canvases[1], "the previous scene canvas survives")
    Assert.equal(renderer.colorDepth, lg.canvases[2], "the previous color-depth canvas survives")
    Assert.equal(renderer.renderState, lg.canvases[3], "the previous render-state canvas survives")
    Assert.equal(renderer.stateDepth, lg.canvases[4], "the previous state-depth canvas survives")
    Assert.equal(renderer.colorW, oldColorW, "the recorded color size survives")
    Assert.equal(renderer.colorH, oldColorH, "the recorded color size survives")
    Assert.equal(renderer.stateW, oldStateW, "the recorded state size survives")
    Assert.equal(renderer.stateH, oldStateH, "the recorded state size survives")
    Assert.equal(renderer._colorTargets, oldColorTargets, "the previous color target descriptor survives")
    Assert.equal(renderer._stateTargets, oldStateTargets, "the previous state target descriptor survives")
    for i = 1, 4 do
      Assert.equal(lg.canvases[i].releaseCount, 0, "the previous canvas " .. i .. " is still owned")
    end

    renderer:release()
    for _, canvas in ipairs(lg.canvases) do
      Assert.equal(canvas.releaseCount, 1, "release cleans up every canvas exactly once")
    end
  end
end

-- Edge configuration is part of target staging: a failure after the new
-- renderState texture was sent but before u_stateSize was accepted restores
-- the previous uniforms, retains the previous published descriptors and
-- canvases, and releases the unpublished replacement set.
function T.canvas_recreation_send_failure_retains_previous_targets()
  -- The first draw's edge-shader sends, in order: 2 target uniforms
  -- (u_renderState/u_stateSize) from _ensureTargets, 1 from _sendEdgeColors,
  -- 13 from _sendFog (u_fogEnabled/u_fogColor + 8 density-table groups +
  -- u_fogOffsetDepth/u_fogShift/u_fogAlpha), and 1 for u_antialiasEnabled --
  -- 17 total. The second (recreating) draw's target uniforms then start at
  -- 18 (u_renderState) and 19 (u_stateSize), so failing on the 19th send
  -- lands on u_stateSize, after u_renderState already succeeded.
  local lg = fakeGraphics({ failOnEdgeShaderSend = 19 })
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local oldViewport = FieldViewport.new(640, 480, { mode = "strict" })
  renderer:draw(scene.runtime, scene.camera, nil, oldViewport)
  local oldColorTargets, oldStateTargets = assert(renderer._colorTargets), assert(renderer._stateTargets)
  local edgeShader = assert(lg.shaders[2])

  local err = Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(1280, 720, { mode = "expanded" }))
  end)
  Assert.isTrue(tostring(err):find("injected edge shader send failure", 1, true) ~= nil, "rethrows send failure")

  Assert.equal(renderer._colorTargets, oldColorTargets, "the previous color descriptor remains published")
  Assert.equal(renderer._stateTargets, oldStateTargets, "the previous state descriptor remains published")
  Assert.equal(renderer.sceneColor, lg.canvases[1], "the previous scene canvas survives")
  Assert.equal(renderer.colorDepth, lg.canvases[2], "the previous color-depth canvas survives")
  Assert.equal(renderer.renderState, lg.canvases[3], "the previous render-state canvas survives")
  Assert.equal(renderer.stateDepth, lg.canvases[4], "the previous state-depth canvas survives")
  Assert.equal(renderer.colorW, 640)
  Assert.equal(renderer.colorH, 480)
  Assert.equal(renderer.stateW, 640)
  Assert.equal(renderer.stateH, 480)
  Assert.equal(edgeShader.uniforms.u_renderState, lg.canvases[3], "the previous renderState binding is restored")
  Assert.deepEqual(edgeShader.uniforms.u_stateSize, { 640, 480 }, "the previous state size is restored")
  for i = 1, 4 do
    Assert.equal(lg.canvases[i].releaseCount, 0, "the previous canvas remains owned")
    Assert.equal(lg.canvases[i + 4].releaseCount, 1, "the unpublished replacement canvas is released")
  end

  renderer:draw(scene.runtime, scene.camera, nil, oldViewport)
  Assert.equal(#lg.canvases, 8, "the retained target set remains usable without allocation")
  renderer:release()
  for _, canvas in ipairs(lg.canvases) do
    Assert.equal(canvas.releaseCount, 1, "release cleans up every canvas exactly once")
  end
end

-- Renderer-owned frame storage is stable while its contents reset. The
-- target descriptors and edge size uniforms change only with target
-- generation. Releasing the canvases clears the descriptors so they cannot
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
  local colorTargets = assert(renderer._colorTargets, "successful canvas creation publishes the color descriptor")
  local stateTargets = assert(renderer._stateTargets, "successful canvas creation publishes the state descriptor")
  Assert.equal(colorTargets[1], renderer.sceneColor)
  Assert.equal(colorTargets.depthstencil, renderer.colorDepth)
  Assert.equal(stateTargets[1], renderer.renderState)
  Assert.equal(stateTargets.depthstencil, renderer.stateDepth)
  Assert.equal(renderer.stats, stats, "draw reuses the public stats table")
  Assert.equal(shaderSendCount(edgeShader, "u_renderState"), 1)
  Assert.equal(shaderSendCount(edgeShader, "u_stateSize"), 1)
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 1, "the first draw establishes the scene edge table")

  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.equal(renderer._colorTargets, colorTargets, "unchanged dimensions reuse the color descriptor")
  Assert.equal(renderer._stateTargets, stateTargets, "unchanged dimensions reuse the state descriptor")
  Assert.equal(renderer.stats, stats, "later draws retain stats identity")
  Assert.equal(shaderSendCount(edgeShader, "u_renderState"), 1, "unchanged targets do not resend the state texture")
  Assert.equal(shaderSendCount(edgeShader, "u_stateSize"), 1, "unchanged size does not resend the state size")
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 1, "the same edge table reference is not resent")

  viewport:resize(1280, 720)
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.isTrue(renderer._colorTargets ~= colorTargets, "replacement publishes a new color descriptor")
  Assert.isTrue(renderer._stateTargets ~= stateTargets, "replacement publishes a new state descriptor")
  Assert.equal(shaderSendCount(edgeShader, "u_renderState"), 2)
  Assert.equal(shaderSendCount(edgeShader, "u_stateSize"), 2)
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 1, "a target resize alone does not resend the edge table")

  -- A different edge table (a new area's scene profile) resends, even though
  -- the raster size and target descriptors are unchanged.
  scene.runtime.edgeColors = edgeColorsFixture()
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 2, "a changed edge table resends")

  -- The DS composites edge color by RGB replacement, not an
  -- alpha-mix scalar; the fidelity path carries no alpha uniform to blend
  -- with.
  Assert.equal(shaderSendCount(edgeShader, "u_edgeAlpha"), 0, "no alpha-mix uniform exists on the fidelity path")

  renderer:release()
  Assert.isNil(renderer._colorTargets, "release clears the color descriptor")
  Assert.isNil(renderer._stateTargets, "release clears the state descriptor")
end

-- The decoded values MapRenderer sends for u_edgeColors are the scene's edge
-- table RGB555 entries expanded into the six-bit combiner domain (0 -> 0,
-- n -> 2n+1, normalized /63) -- not a raw /31 RGB555 float, a placeholder
-- grey, or the wrong index/channel.
function T.draw_sends_the_scene_edge_table_decoded_to_normalized_rgb6()
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
    Assert.deepEqual(sent[i + 1], decodeRgb555ToRgb6Float(fixture[i]), "edge color entry " .. i)
  end
  renderer:release()
end

-- The locked A.5 fixture: RGB555(4,4,4) (packed 4 + 4*32 + 4*1024) must
-- reach the final shader as (9/63, 9/63, 9/63) -- melonDS's expand5to6(4) =
-- 2*4+1 = 9 in the six-bit domain, not 4/31 (the raw RGB555 float) and not
-- 8/63 (the old floor(c5/16) expansion's result for 4).
function T.edge_color_rgb555_4_4_4_expands_to_rgb6_9_63()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local edgeShader = renderer.edgeShader --[[@as any]]
  local packed444 = 4 + 4 * 32 + 4 * 1024
  scene.runtime.edgeColors = { [0] = packed444, 0, 0, 0, 0, 0, 0, 0 }

  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  local sent
  for _, send in ipairs(edgeShader.sends) do
    if send.name == "u_edgeColors" then
      sent = send.values
    end
  end
  assert(sent, "u_edgeColors was sent")
  Assert.deepEqual(sent[1], { 9 / 63, 9 / 63, 9 / 63 }, "RGB555(4,4,4) expands to RGB6(9,9,9), normalized /63")
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

-- A camera missing a usable far plane is a malformed collaborator, not a case
-- to silently default around: the camera's far plane still feeds its own
-- projection matrices (camera:projection()/camera:billboardProjection()),
-- which both passes draw through, so MapRenderer must fail loudly rather
-- than render against an invented projection bound.
function T.draw_requires_a_positive_camera_far_plane()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  scene.camera.far = nil
  Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, viewport)
  end)

  scene.camera.far = 0
  Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, viewport)
  end)

  scene.camera.far = -10
  Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, viewport)
  end)
  renderer:release()
end

-- The resolved HgssFieldFog.runtimePreset shape a compiled scene carries:
-- enabled, packed RGB555 color, raw offset, slope, alpha, and a 32-entry
-- density table -- distinct, non-placeholder values (not the renderer's own
-- idle-default zero/black/false) so a hardcoded-disabled bug cannot hide
-- behind a coincidentally-zero fixture.
local function fogFixture(enabled)
  local table32 = {}
  for i = 1, 32 do
    table32[i] = enabled and ((i - 1) * 4) or 255
  end
  return {
    enabled = enabled,
    color = enabled and (26 + 26 * 32 + 26 * 1024) or (1 + 2 * 32 + 3 * 1024),
    offset = enabled and 0x726F or 17,
    slope = enabled and 3 or 6,
    alpha = enabled and 31 or 0,
    table = table32,
  }
end

-- MapRenderer must send the scene's own resolved fog preset to the final
-- pass shader (edgeShader), not the permanently-disabled idle default and
-- not map.glsl (which owns no fog uniform -- see
-- map_shader_has_no_global_fog_uniforms in the graphics-smoke suite): enable,
-- the RGB555-decoded color, the offset converted into the depth domain
-- (fogOffsetRaw * 0x200), the slope (sent verbatim as the density shift), the
-- alpha (sent verbatim, 0..31, the same 5-bit domain the final shader's
-- fogAlpha5/srcAlpha5 blend operates in -- not normalized, unlike the fog
-- color), and the 32-entry table all reach edgeShader unconditionally
-- (per-frame, like u_view), whether the resolved preset is enabled or
-- disabled -- disabled is data on the preset, never a MapRenderer special
-- case.
function T.draw_sends_the_scenes_resolved_fog_preset_when_enabled()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.runtime.fog = fogFixture(true)
  local shader = lg.shaders[2]

  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  Assert.equal(shader.uniforms.u_fogEnabled, true, "the resolved preset's enable reaches the final pass shader")
  Assert.deepEqual(
    shader.uniforms.u_fogColor,
    decodeRgb555Float(scene.runtime.fog.color),
    "fog color decodes like edge colors"
  )
  Assert.equal(shader.uniforms.u_fogOffsetDepth, 0x726F * 0x200, "the raw offset is converted into the depth domain")
  Assert.equal(shader.uniforms.u_fogShift, 3, "the preset's slope reaches the shader as the density shift verbatim")
  Assert.equal(shader.uniforms.u_fogAlpha, 31, "the preset's alpha reaches the shader verbatim, 0..31")
  local table32 = scene.runtime.fog.table
  for group = 0, 7 do
    Assert.deepEqual(
      shader.uniforms["u_fogTable" .. group],
      { table32[group * 4 + 1], table32[group * 4 + 2], table32[group * 4 + 3], table32[group * 4 + 4] },
      "each 4-entry density-table group reaches its own named uniform"
    )
  end
  renderer:release()
end

function T.draw_sends_the_scenes_resolved_fog_preset_when_disabled()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.runtime.fog = fogFixture(false)
  local shader = lg.shaders[2]

  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  Assert.equal(shader.uniforms.u_fogEnabled, false)
  Assert.deepEqual(shader.uniforms.u_fogColor, decodeRgb555Float(scene.runtime.fog.color))
  Assert.equal(shader.uniforms.u_fogOffsetDepth, 17 * 0x200)
  Assert.equal(shader.uniforms.u_fogShift, 6)
  Assert.equal(shader.uniforms.u_fogAlpha, 0)
  local disabledTable32 = scene.runtime.fog.table
  for group = 0, 7 do
    Assert.deepEqual(shader.uniforms["u_fogTable" .. group], {
      disabledTable32[group * 4 + 1],
      disabledTable32[group * 4 + 2],
      disabledTable32[group * 4 + 3],
      disabledTable32[group * 4 + 4],
    }, "each 4-entry density-table group reaches its own named uniform")
  end
  renderer:release()
end

-- Every compiled HGSS field scene carries a resolved fog preset (global fog
-- is unconditionally resolved per map); a scene missing it is a required
-- collaborator gone missing, not a case MapRenderer defaults around.
function T.draw_requires_the_scenes_fog_preset()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.runtime.fog = nil

  Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  end)
  renderer:release()
end

-- After a failed recreation the renderer stays usable at the previous size,
-- and a later successful recreation swaps in a full new set while releasing
-- the previous set exactly once. The first draw allocates canvases 1-4
-- (sceneColor, colorDepth, renderState, stateDepth); the failed recreation attempt
-- allocates canvas 5 (sceneColor) before failing on canvas 6 (colorDepth).
function T.canvas_recreation_failure_keeps_renderer_usable()
  local lg = fakeGraphics({ failOnNewCanvas = 6 })
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  local oldColorW, oldColorH = renderer.colorW, renderer.colorH

  Assert.throws(function()
    renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(1280, 720, { mode = "expanded" }))
  end)

  -- Drawing at the retained size allocates nothing and still renders.
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  Assert.equal(#lg.canvases, 5, "the old-size draw reuses the retained canvases")
  Assert.equal(renderer.colorW, oldColorW)
  Assert.equal(renderer.colorH, oldColorH)

  -- The next successful recreation replaces the previous set, releasing it
  -- exactly once, and the renderer owns the new set.
  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(1280, 720, { mode = "expanded" }))
  Assert.equal(#lg.canvases, 9, "a full new set was created")
  Assert.equal(lg.canvases[1].releaseCount, 1, "the old scene canvas is released exactly once")
  Assert.equal(lg.canvases[2].releaseCount, 1, "the old color-depth canvas is released exactly once")
  Assert.equal(lg.canvases[3].releaseCount, 1, "the old render-state canvas is released exactly once")
  Assert.equal(lg.canvases[4].releaseCount, 1, "the old state-depth canvas is released exactly once")
  Assert.equal(lg.canvases[6].releaseCount, 0, "the new scene canvas is owned by the renderer")
  Assert.equal(lg.canvases[9].releaseCount, 0, "the new state-depth canvas is owned by the renderer")

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
  -- beyond it, and each item in the given parts draws exactly twice -- once
  -- into the state pass, once into the color pass.
  renderer:draw(scene.runtime, scene.camera, nil, viewport)
  local emptyFrame = lg.getDrawCalls()
  renderer:draw(scene.runtime, scene.camera, {
    { drawItem("a") },
    { drawItem("b") },
  }, viewport)
  local itemFrame = lg.getDrawCalls() - emptyFrame
  Assert.equal(itemFrame - emptyFrame, 4, "each given world item draws once per pass (state + color)")

  local scratch = renderer._queueScratch
  Assert.isTrue(type(scratch) == "table", "the renderer owns queue scratch")
  local opaque = scratch.opaque
  local cutout = scratch.cutout
  local blended = scratch.blended
  local wireframe = scratch.wireframe

  renderer:draw(scene.runtime, scene.camera, { { drawItem("next") } }, viewport)
  Assert.equal(renderer.stats.drawCalls, 2, "a smaller frame retains no stale draw items (1 item x 2 passes)")
  Assert.isTrue(renderer._queueScratch == scratch)
  Assert.isTrue(scratch.opaque == opaque)
  Assert.isTrue(scratch.cutout == cutout)
  Assert.isTrue(scratch.blended == blended)
  Assert.isTrue(scratch.wireframe == wireframe)

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

-- HGSS initializes the clear/rear-plane polygon ID to the real, reachable DS
-- polygon-id value 0x3F (63) -- it is not a value carved out of the 0..63
-- domain (pokeheartgold: the field renderer's clear-buffer setup; GBATEK
-- POLYGON_ATTR polygon ID is 6 bits wide, so 63 is the largest real id, not a
-- sentinel outside it). MapRenderer must expose this as a named constant, not
-- an invented out-of-domain value like the retired REAR_PLANE_ID (255).
function T.clear_polygon_id_is_the_hgss_rear_plane_value()
  Assert.equal(MapRenderer.CLEAR_POLYGON_ID, 63, "HGSS's real clear polygon id is 0x3F (63), a reachable DS id")
end

-- The root of the "invented 255 sentinel" bug: because opaque/cutout/
-- translucent draws normalized their real polygon id by 255 while the
-- clear/rear-plane entry stamped a fixed value representing 255 in that same
-- domain, a real polygon legitimately using id 63 (the same id as the clear
-- plane) encoded to a completely different id/depth-target value than the
-- clear background -- so it always looked like a different polygon to the
-- edge predicate and spuriously outlined against empty space. Once both are
-- normalized by the true domain maximum (CLEAR_POLYGON_ID == 63), a real
-- polygon 63 and the clear background must encode to exactly the same value,
-- so the edge predicate's "different id" check correctly sees them as the
-- same polygon.
function T.a_real_polygon_63_encodes_the_same_id_value_as_the_clear_background()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local item = passItem("opaque", 0)
  item.polygonId = 63

  renderer:draw(scene.runtime, scene.camera, { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))

  -- Only the state-pass shader (shaders[3]) carries a polygon-ID uniform.
  local sentPolygonId
  for _, send in ipairs(lg.shaders[3].sends) do
    if send.name == "u_polygonId" then
      sentPolygonId = send.values[1]
    end
  end
  -- The state target's own clear call is the draw's first clear.
  local clearIdChannel = lg.calls.clear[1][1][1]
  Assert.equal(
    sentPolygonId,
    clearIdChannel,
    "a real polygon using HGSS's real clear id (63) must encode to exactly the same id/depth-target value "
      .. "as the clear background, or it spuriously edges against empty space"
  )
  renderer:release()
end

-- The opaque polygon-ID field survives translucent drawing rather
-- than being replaced by an invented sentinel (melonDS: the ID/depth
-- attribute the edge pass reads is not one value overloaded to also mean
-- "translucent"). A translucent item's own polygon ID is a distinct,
-- independent attribute -- it must send exactly the same normalization every
-- opaque/cutout item sends, by the real domain maximum (63), never a value
-- carved out of the polygon-ID domain to signal translucency.
-- An ordinary translucent item never reaches the state pass at all (only
-- opaque/cutout/mixed-opaque/wireframe touch renderState/stateDepth -- see
-- MapRenderer:draw), so it sends no u_polygonId anywhere; this locks that it
-- is not, for example, routed through the state pass with an invented
-- sentinel ID merely because it is translucent.
function T.translucent_draws_send_their_own_polygon_id_not_an_invented_sentinel()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local item = passItem("translucent", -1)
  item.polygonId = 7

  renderer:draw(scene.runtime, scene.camera, { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))

  Assert.equal(
    shaderSendCount(lg.shaders[3], "u_polygonId"),
    0,
    "an ordinary translucent item never draws into the state pass"
  )
  renderer:release()
end

-- An ordinary field actor is not a separate sprite renderer -- FieldActorDraw.item builds the
-- exact same render-item shape terrain/building queueing does, so it must
-- reach MapRenderer's one shared _drawMesh path and send the same uniform
-- contract, carrying the ROM's own actor polygon state (modulation,
-- lightMask 1, polygonId 0, cutout alpha) rather than a hard-coded/actor-only
-- substitute. Built through the real production FieldActorDraw/
-- FieldActorFixture path, not a hand-authored item table.
function T.actor_draw_item_reaches_the_shared_world_pipeline_with_its_rom_polygon_state()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()

  local function stubMesh()
    return { setTexture = function() end }
  end
  local visual = FieldActorFixture.visual(99)
  local entry = {
    visual = visual,
    image = { id = 99 },
    meshes = { stubMesh(), stubMesh(), stubMesh(), stubMesh(), stubMesh() },
    billboardScales = { [visual.render.geometry] = { 1, 1, 1 } },
  }
  local record = {
    actorId = "map:1:object:0",
    spriteId = 99,
    world = { x = 2, y = 0, z = -6 },
    facing = "south",
    pose = "idle",
    poseTick = 0,
    visible = true,
  }
  local item = FieldActorDraw.item(record, entry)
  Assert.equal(item.alphaClass, "cutout", "the fixture's actor material is the ROM's cutout class")

  renderer:draw(scene.runtime, scene.camera, { { item } }, FieldViewport.new(640, 480, { mode = "strict" }))

  local colorShader, stateShader = lg.shaders[1], lg.shaders[3]
  local sent, stateSent = {}, {}
  for _, send in ipairs(colorShader.sends) do
    sent[send.name] = send.values[1]
  end
  for _, send in ipairs(stateShader.sends) do
    stateSent[send.name] = send.values[1]
  end
  Assert.equal(sent.u_polygonMode, 0, "the actor's modulation material sends the modulation combiner id")
  Assert.equal(stateSent.u_polygonId, 0 / 63, "the actor's polygon id 0 rides the real id channel in the state pass")
  Assert.equal(sent.u_fragmentPass, 1, "the actor's cutout class sends the color-pass cutout fragment-pass id")
  Assert.equal(stateSent.u_fragmentPass, 1, "the actor's cutout class sends the state-pass cutout fragment-pass id")
  Assert.deepEqual(sent.u_lightMask, MapRenderer.lightMaskUniforms(1), "light mask 1 decodes to bit 0 only")
  Assert.notNil(
    sent.u_billboardCenter,
    "the actor's billboard projection selection reaches the shared billboard branch"
  )
  Assert.equal(
    #lg.shaders,
    3,
    "the actor drew through the shared color/state shaders, no separate sprite shader was created"
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
    4,
    "state-pass start, color-pass start, translucent write-on, and color wireframe passes"
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

  renderer:_drawStraddle(item, Matrix4.identity(), 0)
  renderer:_drawWireframeStraddle(item, Matrix4.identity())

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

-- ---- wireframe polygon-id/opaque-classification semantics ----
--
-- The DS draws polygon alpha zero (wireframe) as ordinary opaque geometry
-- with its own real POLYGON_ATTR polygon id -- there is no separate
-- "wireframe id" register on real hardware. The renderer must send that same
-- real id, never a value invented to mean "this is a wireframe/rear-plane
-- draw" (see MapRenderer.CLEAR_POLYGON_ID for the one real DS sentinel value,
-- which is a legitimate polygon id, not a wireframe-specific one). Only the
-- state pass's wireframe draw carries a polygon-ID uniform at all -- the
-- color shader no longer owns any ID/fog-gate output.
function T.wireframe_draw_sends_its_own_real_polygon_id_not_an_invented_sentinel()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local item = passItem("wireframe", 0)
  item.polygonId = 37

  renderer:_drawStateWireframe(item, Matrix4.identity())

  local sent
  for _, send in ipairs(lg.shaders[3].sends) do
    if send.name == "u_polygonId" then
      sent = send.values[1]
    end
  end
  Assert.equal(sent, item.polygonId / 63, "a wireframe draw sends its own real polygon id, never a sentinel")
  renderer:release()
end

-- GBATEK: "Edge Marking is applied ONLY to opaque polygons (including
-- wire-frames)" -- a wireframe draw must be classified as opaque for the
-- fragment-pass uniform the edge/fog final pass keys on (never the
-- cutout/mixed-opaque discard branches). This locks a contract the renderer
-- already satisfies structurally so a later refactor cannot regress it
-- silently. Both the color and state wireframe draw bodies always send the
-- opaque fragment-pass id.
function T.wireframe_draw_is_opaque_classified_for_edge_marking()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local item = passItem("wireframe", 0)

  renderer:_drawWireframe(item, Matrix4.identity())
  renderer:_drawStateWireframe(item, Matrix4.identity())

  local colorSent, stateSent = {}, {}
  for _, send in ipairs(lg.shaders[1].sends) do
    colorSent[send.name] = send.values[1]
  end
  for _, send in ipairs(lg.shaders[3].sends) do
    stateSent[send.name] = send.values[1]
  end
  Assert.equal(colorSent.u_fragmentPass, 0, "a color-pass wireframe draw sends the opaque fragment-pass id")
  Assert.equal(stateSent.u_fragmentPass, 0, "a state-pass wireframe draw sends the opaque fragment-pass id")
  renderer:release()
end

-- The renderState render-target contract's blue channel is the per-polygon
-- fog gate (item.fogEnabled), not a separate "translucent identity" flag --
-- the old u_translucentAttribute uniform is retired outright, not merely
-- unread, for every draw kind (opaque, cutout, translucent, wireframe
-- alike). A stray send of the retired uniform is exactly the kind of silent
-- regression this locks: a shader still reading it would compile and render,
-- so only an explicit "never sent" assertion catches its reintroduction.
function T.draws_never_send_the_retired_translucent_attribute_uniform()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local opaqueItem = passItem("opaque", 0)
  local cutoutItem = passItem("cutout", 0)
  local translucentItem = passItem("translucent", -1)
  local wireframeItem = passItem("wireframe", 0)

  renderer:draw(
    scene.runtime,
    scene.camera,
    { { opaqueItem, cutoutItem, translucentItem, wireframeItem } },
    FieldViewport.new(640, 480, { mode = "strict" })
  )

  Assert.equal(
    shaderSendCount(lg.shaders[1], "u_translucentAttribute"),
    0,
    "the map shader is never sent the retired translucent-attribute uniform"
  )
  renderer:release()
end

-- The render queue is built exactly once per frame and both passes consume
-- it -- never a separate actor queue or a second full buildInto call.
-- RenderQueue.buildInto is a pure module function (no instance to inject),
-- so this spies on it directly rather than adding a production test-only
-- global counter, and restores it immediately afterward regardless of
-- outcome so no other test observes the wrapped function.
function T.draw_builds_the_render_queue_exactly_once_per_frame()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local original = RenderQueue.buildInto
  local callCountValue = 0
  ---@diagnostic disable-next-line: duplicate-set-field -- intentional: a temporary spy, restored below
  RenderQueue.buildInto = function(...)
    callCountValue = callCountValue + 1
    return original(...)
  end

  local ok, err = pcall(function()
    renderer:draw(
      scene.runtime,
      scene.camera,
      { { passItem("opaque", 0) } },
      FieldViewport.new(640, 480, { mode = "strict" })
    )
  end)
  RenderQueue.buildInto = original
  if not ok then
    error(err)
  end

  Assert.equal(callCountValue, 1, "MapRenderer:draw builds the render queue exactly once per frame")
  renderer:release()
end

-- Both the state and color passes must select projection identically per
-- item: an ordinary item always draws through camera:projection(), a
-- billboard item always through camera:billboardProjection() -- in both
-- passes, never mismatched between them.
function T.projection_selection_matches_between_the_state_and_color_passes()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local worldProjection = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  local billboardProjection = { 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2 }
  scene.camera.projection = function()
    return worldProjection
  end
  scene.camera.billboardProjection = function()
    return billboardProjection
  end

  local ordinary = passItem("opaque", 0)
  local billboard = passItem("opaque", 0)
  billboard.billboardCenter = { 0, 0, -5 }
  billboard.billboardScale = { 1, 1, 1 }
  billboard.billboardProjection = true

  renderer:draw(
    scene.runtime,
    scene.camera,
    { { ordinary, billboard } },
    FieldViewport.new(640, 480, { mode = "strict" })
  )

  local function projectionsSentBy(shader)
    local sent = {}
    for _, send in ipairs(shader.sends) do
      if send.name == "u_proj" then
        sent[#sent + 1] = send.values[2]
      end
    end
    return sent
  end

  local colorProjections = projectionsSentBy(lg.shaders[1])
  local stateProjections = projectionsSentBy(lg.shaders[3])
  Assert.deepEqual(colorProjections, { worldProjection, billboardProjection }, "color pass: ordinary then billboard")
  Assert.deepEqual(stateProjections, { worldProjection, billboardProjection }, "state pass: ordinary then billboard")
  renderer:release()
end

-- The field camera selects DS Z buffering (GX_BUFFERMODE_Z), so the state
-- shader derives depth from the fragment's normalized window depth; the
-- retired camera-far depth-normalization uniform must not be sent to the
-- state pass (or any pass) anymore. The state shader is lg.shaders[3] (the
-- color/resolve shaders are shaders[1]/shaders[2]).
function T.draw_never_sends_the_retired_depth_normalization_uniform()
  local lg = fakeGraphics()
  local renderer = MapRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.camera.far = 123.5

  renderer:draw(scene.runtime, scene.camera, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  Assert.equal(shaderSendCount(lg.shaders[1], "u_depthWMax"), 0, "the color shader never receives the retired uniform")
  Assert.equal(
    shaderSendCount(lg.shaders[2], "u_depthWMax"),
    0,
    "the final-pass shader never receives the retired uniform"
  )
  Assert.equal(
    shaderSendCount(lg.shaders[3], "u_depthWMax"),
    0,
    "the state shader derives depth from window depth, not a far-plane normalization"
  )
  renderer:release()
end

-- The DS Z conversion -- windowZ -> ndcZ = 2*windowZ - 1, ndcZ scaled by
-- 0x4000 with truncation toward zero (GLSL int() truncates, so a fractional
-- negative NDC must not floor), offset by 0x3FFF, scaled by 0x200, clamped
-- to 0..0xFFFFFF -- as a pure table, independently hand-computed (never
-- calling the production shader). Anchors: the near plane clamps to 0; the
-- exact midpoint 0.5 maps to 0x7FFE00 (the +0x3FFF offset); the far plane 1
-- maps to 0xFFFE00, distinct from the 0xFFFFFF clear/rear-plane value; the
-- negative-NDC fractional case 0.4 truncates -3276.8 to -3276 (0x666600),
-- not floor's -3277 (0x665E00).
function T.field_depth_conversion_table_matches_the_ds_z_formula()
  local function trunc(x)
    return x >= 0 and math.floor(x) or math.ceil(x)
  end
  local function dsZ(windowZ)
    local ndc = windowZ * 2 - 1
    local ndc14 = trunc(ndc * 0x4000)
    local depth = (ndc14 + 0x3FFF) * 0x200
    if depth < 0 then
      depth = 0
    elseif depth > 0xFFFFFF then
      depth = 0xFFFFFF
    end
    return depth
  end

  Assert.equal(dsZ(0), 0, "windowZ=0 maps to DS depth 0 after clamping the signed formula")
  Assert.equal(dsZ(0.5), 0x7FFE00, "windowZ=0.5 maps to the exact midpoint depth 0x7FFE00")
  Assert.equal(dsZ(1), 0xFFFE00, "windowZ=1 maps to 0xFFFE00 -- the DS far value, below the 0xFFFFFF clear/rear plane")
  Assert.equal(dsZ(0.4), 0x666600, "windowZ=0.4 (ndc*0x4000 = -3276.8) truncates to -3276 -> 0x666600")
  Assert.equal(dsZ(0) < dsZ(0.5) and dsZ(0.5) < dsZ(1), true, "the mapping is monotonic across the anchors")
end

return { tests = T }
