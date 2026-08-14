-- Pure MapRenderer contracts that need no graphics context: the field-edge
-- radius derivation, the per-draw light-mask encoding, the straddle bend
-- bake, and the scene-schema gate. Everything that compiles a shader,
-- allocates a render target, or reads back driver state lives in
-- map_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local FieldViewport = require("libs.engine.src.FieldViewport")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

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
    getDrawCalls = function()
      return drawCalls
    end,
    newShader = function(source)
      shaderCount = shaderCount + 1
      if opts.failOnNewShader == shaderCount then
        error("injected shader failure")
      end
      local shader = { source = source, releaseCount = 0 }
      shader.send = function() end
      shader.release = function()
        shader.releaseCount = shader.releaseCount + 1
      end
      shaders[#shaders + 1] = shader
      return shader
    end,
    newCanvas = function()
      canvasCount = canvasCount + 1
      if opts.failOnNewCanvas == canvasCount then
        error("injected canvas failure")
      end
      local canvas = { releaseCount = 0 }
      canvas.setFilter = function() end
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

function T.rejects_stale_scene_schema()
  local ok, err = pcall(MapSceneLoader.load, nil, { schema = "g4-map-scene-v1" })
  Assert.isTrue(
    not ok and err.code == "MAP_SCENE_UNSUPPORTED_SCHEMA",
    "rejects old scene schema: " .. tostring(err.code)
  )
end

-- The exact restoration contract (spec 30.31): every captured caller state
-- comes back equal to its pre-draw value, never a hard-coded default.
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

-- Construction is transactional (spec 30.32): when the second shader fails,
-- the first must be released and the failure must reach the caller.
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
    Assert.equal(lg.canvases[1].releaseCount, 0, "the previous scene canvas is still owned")
    Assert.equal(lg.canvases[2].releaseCount, 0, "the previous id-depth canvas is still owned")
    Assert.equal(lg.canvases[3].releaseCount, 0, "the previous depth canvas is still owned")

    renderer:release()
    for _, canvas in ipairs(lg.canvases) do
      Assert.equal(canvas.releaseCount, 1, "release cleans up every canvas exactly once")
    end
  end
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

-- The compact per-draw uniform (spec 30.33): one vec4 of 0/1 floats, bit i =
-- light i of the polygon's 4-bit mask. Different masks decode to different
-- uniforms and mask 0 to all-off.
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
  local meshes = {}
  local wireframeCount = 0
  return {
    meshes = meshes,
    wireframeCount = function()
      return wireframeCount
    end,
    newShader = function()
      return { send = function() end }
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
    setWireframe = function(enabled)
      if enabled then
        wireframeCount = wireframeCount + 1
      end
    end,
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

-- The straddle draw bakes the shared mesh's vertices into a scratch mesh
-- that carries the source's vertex map, draws it, and releases it within
-- the call -- the shared pool mesh is never mutated.
function T.straddle_draw_bakes_into_a_released_scratch_with_the_source_map()
  local fake = straddleGraphics()
  local renderer = MapRenderer.new({ graphics = fake })
  local source = sourceMesh()
  local item = straddleDrawItem(source)

  renderer:_drawStraddle(item, Matrix4.identity(), nil, Matrix4.identity())

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
    renderer:_drawStraddle(straddleDrawItem(sourceMesh()), Matrix4.identity(), nil, Matrix4.identity())
  end)

  Assert.equal(#fake.meshes, 1)
  Assert.isTrue(fake.meshes[1].released, "a failed straddle draw releases its scratch")
end

-- ---- wireframe straddle dispatch ----
--
-- The wireframe pass routes straddling items through the same per-vertex
-- bend as the filled passes (the corpus has one real straddle+wireframe
-- case: indoor:146:e8aca8e43479 in map 0080), so a wireframe straddle item
-- bakes its leading vertices under the straddle transform, draws the scratch
-- with wireframe mode on, and releases it within the call.
function T.wireframe_straddle_bakes_into_a_released_scratch_drawn_in_wireframe()
  local fake = straddleGraphics()
  local renderer = MapRenderer.new({ graphics = fake })
  local item = straddleDrawItem(sourceMesh())

  renderer:_drawWireframe(item, Matrix4.identity(), Matrix4.identity())

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
  Assert.equal(fake.wireframeCount(), 1, "the straddle scratch draws in wireframe mode")
end

-- A non-straddling wireframe item draws its own mesh directly, without
-- baking a scratch.
function T.wireframe_draw_without_a_straddle_uses_the_item_mesh()
  local fake = straddleGraphics()
  local renderer = MapRenderer.new({ graphics = fake })
  local item = straddleDrawItem(sourceMesh())
  item.straddle = nil

  renderer:_drawWireframe(item, Matrix4.identity(), Matrix4.identity())

  Assert.equal(#fake.meshes, 0, "no scratch is baked for a non-straddling wireframe item")
  Assert.equal(fake.wireframeCount(), 1, "the item mesh draws in wireframe mode")
end

-- A draw failure inside the wireframe straddle path must still release the
-- scratch mesh it already acquired.
function T.a_failed_wireframe_straddle_draw_still_releases_the_scratch()
  local fake = straddleGraphics({ failOnDraw = true })
  local renderer = MapRenderer.new({ graphics = fake })

  Assert.throws(function()
    renderer:_drawWireframe(straddleDrawItem(sourceMesh()), Matrix4.identity(), Matrix4.identity())
  end)

  Assert.equal(#fake.meshes, 1)
  Assert.isTrue(fake.meshes[1].released, "a failed wireframe straddle draw releases its scratch")
end

return { tests = T }
