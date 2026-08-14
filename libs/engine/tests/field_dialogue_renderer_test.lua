-- Failure-path and frame-resolution tests for the dialogue renderer, driven
-- through an injected graphics namespace so the Nth-construction and
-- mid-draw failures can be provoked deterministically: a quad failure after
-- the atlas and frame strip exist must release what was acquired, a missing
-- generated UI manifest or frame strip is a typed error, and the player's
-- selected frame index resolves the manifest strip rect (frame 0 vs frame 1
-- sample different rows, both composed by the canonical frame tilemap). A
-- draw that raises must still balance the transform stack and restore every
-- captured graphics state. The real-context smokes live in
-- field_dialogue_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

-- Tracks created images and their release calls, records every draw with its
-- quad and position, tracks the transform-stack depth, and holds a full
-- settable state the renderer must restore exactly.
-- failOnQuadCall/failOnDrawCall make the Nth construction/draw call raise.
-- imageSizes supplies the created image dimensions in creation order.
local function fakeGraphics(opts)
  opts = opts or {}
  local images = {}
  local quadCalls, drawCalls = 0, 0
  local pushDepth = 0
  local draws = {}
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
    scissor = opts.scissor,
  }
  return {
    images = images,
    draws = draws,
    pushDepth = function()
      return pushDepth
    end,
    newImage = function()
      local size = opts.imageSizes and opts.imageSizes[#images + 1] or { 16, 16 }
      local image = {
        released = false,
        setFilter = function() end,
        getWidth = function()
          return size[1]
        end,
        getHeight = function()
          return size[2]
        end,
      }
      image.release = function()
        image.released = true
      end
      images[#images + 1] = image
      return image
    end,
    newQuad = function(x, y, w, h, imgW, imgH)
      quadCalls = quadCalls + 1
      if opts.failOnQuadCall == quadCalls then
        error("injected newQuad failure")
      end
      return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    end,
    push = function()
      pushDepth = pushDepth + 1
    end,
    pop = function()
      pushDepth = pushDepth - 1
    end,
    translate = function() end,
    scale = function() end,
    setColor = function(r, g, b, a)
      state.color = { r, g, b, a }
    end,
    getColor = function()
      return state.color[1], state.color[2], state.color[3], state.color[4]
    end,
    draw = function(image, quad, x, y)
      drawCalls = drawCalls + 1
      draws[#draws + 1] = { image = image, quad = quad, x = x, y = y }
      if opts.failOnDrawCall == drawCalls then
        error("injected draw failure")
      end
    end,
    polygon = function() end,
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
    getScissor = function()
      if not state.scissor then
        return nil
      end
      return state.scissor[1], state.scissor[2], state.scissor[3], state.scissor[4]
    end,
    setScissor = function(x, y, w, h)
      state.scissor = { x, y, w, h }
    end,
  }
end

local function uiCache()
  return FieldUiFixture.cacheWithFontAndFrames()
end

function T.missing_def_is_a_typed_error()
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()) })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FONT_DEF_MISSING", "raises FONT_DEF_MISSING")
end

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    ---@diagnostic disable: assign-type-mismatch
    FieldDialogueRenderer.new({ cacheFs = uiCache(), graphics = false })
  end)
  Assert.isTrue(tostring(err):find("FieldDialogueRenderer requires love.graphics", 1, true) ~= nil)
end

-- The generated UI class is a required renderer asset: without its manifest
-- the renderer cannot resolve the frame strip at all.
function T.missing_ui_manifest_is_a_typed_error()
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont() })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_UI_MANIFEST_MISSING", "raises FIELD_UI_MANIFEST_MISSING")
end

-- The manifest names the frame strip; a cache without the PNG must not build
-- a half-frame renderer. The already-acquired font atlas is released.
function T.missing_frame_strip_is_a_typed_error_and_releases_the_atlas()
  local cache = FieldDialogueFixture.cacheWithFont()
  cache:writeLua("data/generated/field/ui/ui.lua", FieldUiFixture.manifest())
  local lg = fakeGraphics({ imageSizes = { { 16, 16 } } })
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = cache, graphics = lg })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_UI_FRAME_ATLAS_MISSING", "raises FIELD_UI_FRAME_ATLAS_MISSING")
  Assert.equal(#lg.images, 1, "the font atlas was acquired before the strip failed")
  Assert.equal(lg.images[1].released, true, "the acquired atlas was released")
end

-- A quad failure after the atlas and frame strip were created must release
-- both acquired images before the constructor rethrows.
function T.constructor_failure_releases_atlas_and_frame_strip()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 144, 16 } }, failOnQuadCall = 1 })
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = uiCache(), graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil, "rethrows the quad failure")
  Assert.equal(#lg.images, 2, "atlas and frame strip were created before the failure")
  Assert.equal(lg.images[1].released, true, "the atlas was released")
  Assert.equal(lg.images[2].released, true, "the frame strip was released")
end

-- A failure between graphics.push() and graphics.pop() must still pop the
-- transform stack and restore every captured graphics state exactly.
function T.draw_failure_balances_transform_stack_and_restores_state()
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
    scissor = { 4, 8, 32, 16 },
    imageSizes = { { 16, 16 }, { 144, 16 } },
    failOnDrawCall = 1,
  })
  local renderer = FieldDialogueRenderer.new({ cacheFs = uiCache(), graphics = lg })
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })

  local err = Assert.throws(function()
    renderer:draw(controller, viewport)
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced after a failed draw")
  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)

  renderer:release()
end

-- The former nine-slice window is gone: the renderer owns only the font atlas
-- and the frame strip, creates no third slice source image, and draws the
-- frame from the generated strip tiles.
function T.no_nine_slice_assets_are_built()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 144, 16 } } })
  local renderer = FieldDialogueRenderer.new({ cacheFs = uiCache(), graphics = lg })
  Assert.equal(#lg.images, 2, "only the font atlas and the frame strip are created")

  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  renderer:draw(controller, FieldViewport.new(256, 192, { mode = "expanded" }))
  Assert.equal(#lg.images, 2, "drawing creates no slice image")
  renderer:release()
end

-- The selected frame index resolves the manifest strip rect: frame 0 samples
-- the first strip row, frame 1 the second, and both place the tiles by the
-- canonical DrawFrameAndWindow2 tilemap around the content box.
function T.frame_index_resolves_the_manifest_strip_tiles()
  local function renderedDraws(frameIndex)
    local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 144, 16 } } })
    local renderer = FieldDialogueRenderer.new({ cacheFs = uiCache(), graphics = lg })
    local controller = FieldDialogueFixture.openDialogue("AB", frameIndex)
    renderer:draw(controller, FieldViewport.new(256, 192, { mode = "expanded" }))
    renderer:release()
    return lg.draws
  end

  local frame0 = renderedDraws(0)
  Assert.equal(frame0[1].x, 0, "top-left corner tile at (0,144)")
  Assert.equal(frame0[1].y, 144)
  Assert.deepEqual(
    { frame0[1].quad.x, frame0[1].quad.y, frame0[1].quad.w, frame0[1].quad.h },
    { 0, 0, 8, 8 },
    "tile 0 quad samples the strip's first row"
  )
  Assert.equal(frame0[1].quad.imgW, 144, "frame quads sample the strip atlas")

  -- The top edge is one tile repeated across the 27 content tiles.
  local topEdge = 0
  local expectedX = 16
  for _, call in ipairs(frame0) do
    if call.quad.x == 16 and call.quad.y == 0 then
      topEdge = topEdge + 1
      Assert.equal(call.x, expectedX, "top edge tile spans x=16..232")
      Assert.equal(call.y, 144)
      expectedX = expectedX + 8
    end
  end
  Assert.equal(topEdge, 27, "the top edge repeats the tile across 27 tiles")

  local frame1 = renderedDraws(1)
  Assert.deepEqual({ frame1[1].quad.x, frame1[1].quad.y }, { 0, 8 }, "frame 1 tiles sample the second strip row")
  Assert.equal(frame1[1].x, 0)
  Assert.equal(frame1[1].y, 144, "frame change moves artwork, not geometry")
end

-- A request without a frame index (a host that carries no player options)
-- still draws its text; no frame tiles are fabricated.
function T.request_without_a_frame_index_draws_no_frame_tiles()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 144, 16 } } })
  local renderer = FieldDialogueRenderer.new({ cacheFs = uiCache(), graphics = lg })
  local controller = FieldDialogueFixture.openDialogue("AB")
  renderer:draw(controller, FieldViewport.new(256, 192, { mode = "expanded" }))
  for _, call in ipairs(lg.draws) do
    Assert.equal(call.quad.imgW, 16, "only font-atlas quads are drawn without a frame index")
  end
  renderer:release()
end

return { tests = T }
