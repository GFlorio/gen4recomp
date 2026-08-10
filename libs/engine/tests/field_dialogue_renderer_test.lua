-- Failure-path tests for the dialogue renderer, driven through an injected
-- graphics namespace so the Nth-construction and mid-draw failures can be
-- provoked deterministically: a quad failure after the atlas exists must
-- release what was acquired, and a draw that raises must still balance the
-- transform stack and restore every captured graphics state. The real-context
-- smokes live in field_dialogue_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local Errors = require("libs.rom.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

-- Tracks created images and their release calls, the transform-stack depth, and
-- a full settable state the renderer must restore exactly.
-- failOnQuadCall/failOnDrawCall make the Nth construction/draw call raise.
local function fakeGraphics(opts)
  opts = opts or {}
  local images = {}
  local quadCalls, drawCalls = 0, 0
  local pushDepth = 0
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
    pushDepth = function()
      return pushDepth
    end,
    newImage = function()
      local image = {
        released = false,
        setFilter = function() end,
        getWidth = function()
          return 16
        end,
        getHeight = function()
          return 16
        end,
      }
      image.release = function()
        image.released = true
      end
      images[#images + 1] = image
      return image
    end,
    newQuad = function()
      quadCalls = quadCalls + 1
      if opts.failOnQuadCall == quadCalls then
        error("injected newQuad failure")
      end
      return { quad = quadCalls }
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
    draw = function()
      drawCalls = drawCalls + 1
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

function T.missing_def_is_a_typed_error()
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()) })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FONT_DEF_MISSING", "raises FONT_DEF_MISSING")
end

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = false })
  end)
  Assert.isTrue(tostring(err):find("FieldDialogueRenderer requires love.graphics", 1, true) ~= nil)
end

-- A quad/slice failure after the atlas was created must release the acquired
-- images before the constructor rethrows.
function T.constructor_failure_releases_the_acquired_atlas()
  local lg = fakeGraphics({ failOnQuadCall = 1 })
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil, "rethrows the quad failure")
  Assert.equal(#lg.images, 1, "the atlas was created before the failure")
  Assert.equal(lg.images[1].released, true, "the acquired atlas was released")
end

-- A failure during slice quads happens after the slice image was created;
-- both acquired images must be released.
function T.constructor_failure_releases_atlas_and_slice_image()
  local lg = fakeGraphics({ failOnQuadCall = 4 })
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil, "rethrows the quad failure")
  Assert.equal(#lg.images, 2, "atlas and slice image were created before the failure")
  Assert.equal(lg.images[1].released, true, "the atlas was released")
  Assert.equal(lg.images[2].released, true, "the slice image was released")
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
    failOnDrawCall = 1,
  })
  local renderer = FieldDialogueRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = lg })
  local controller = FieldDialogueFixture.openDialogue("AB")
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })

  local err = Assert.throws(function()
    renderer:draw(controller, viewport)
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced after a failed draw")
  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)

  renderer:release()
end

return T
