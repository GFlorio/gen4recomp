-- Failure-path and manifest-authority tests for the Start Menu renderer,
-- driven through an injected graphics namespace so the Nth-construction and
-- mid-draw failures can be provoked deterministically. The renderer resolves
-- the whole canonical surface from the generated manifest's `startMenu`
-- section (background rect, slot rects, icon mapping, cursor frames with
-- durations) and never repeats source coordinates; a quad failure after the
-- background and cursor images exist must release both, and a missing
-- manifest, background, or cursor asset is a typed error. Drawing the
-- surface uses only the two generated images -- no generic field-menu theme
-- colors or primitives -- and a draw that raises must still balance the
-- transform stack and restore every captured graphics state. The
-- real-context smokes live in start_menu_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local StartMenuRenderer = require("libs.engine.src.StartMenuRenderer")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

-- Tracks created images and their release calls, records every draw with its
-- quad, position, and the color at draw time, records any themed-primitive
-- call (rectangle/polygon/print must never be used for this surface), tracks
-- the transform-stack depth, and holds a full settable state the renderer
-- must restore exactly. failOnQuadCall/failOnDrawCall make the Nth
-- construction/draw call raise; imageSizes supplies the created image
-- dimensions in creation order.
local function fakeGraphics(opts)
  opts = opts or {}
  local images = {}
  local quadCalls, drawCalls = 0, 0
  local pushDepth = 0
  local draws = {}
  local primitives = {}
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
  local function callPrimitive(name)
    primitives[#primitives + 1] = name
  end
  return {
    images = images,
    draws = draws,
    primitives = primitives,
    pushDepth = function()
      return pushDepth
    end,
    newImage = function()
      local size = opts.imageSizes and opts.imageSizes[#images + 1] or { 256, 192 }
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
      draws[#draws + 1] = { image = image, quad = quad, x = x, y = y, color = state.color }
      if opts.failOnDrawCall == drawCalls then
        error("injected draw failure")
      end
    end,
    rectangle = function()
      callPrimitive("rectangle")
    end,
    polygon = function()
      callPrimitive("polygon")
    end,
    print = function()
      callPrimitive("print")
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

local function canonicalViewport()
  return FieldViewport.new(256, 192, { mode = "expanded" })
end

local function menuCache()
  return FieldUiFixture.startMenuCache()
end

function T.missing_manifest_is_a_typed_error()
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()) })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_UI_MANIFEST_MISSING", "raises FIELD_UI_MANIFEST_MISSING")
end

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    ---@diagnostic disable: assign-type-mismatch
    StartMenuRenderer.new({ cacheFs = menuCache(), graphics = false })
  end)
  Assert.isTrue(tostring(err):find("StartMenuRenderer requires love.graphics", 1, true) ~= nil)
end

-- The manifest must carry the whole startMenu surface: without the section
-- the renderer cannot resolve anything it draws.
function T.missing_start_menu_section_is_a_typed_error()
  local cache = menuCache()
  local manifest = FieldUiFixture.manifest()
  manifest.startMenu = nil
  cache:writeLua("data/generated/field/ui/ui.lua", manifest)
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = cache })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_UI_MANIFEST_INVALID", "raises FIELD_UI_MANIFEST_INVALID")
end

-- The manifest names the background and cursor assets; a cache without the
-- background PNG must not build a half-surface renderer.
function T.missing_background_asset_is_a_typed_error()
  local cache = menuCache()
  cache:remove(FieldUiFixture.START_MENU_BACKGROUND_PATH)
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = cache })
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_UI_START_MENU_BACKGROUND_MISSING",
    "raises FIELD_UI_START_MENU_BACKGROUND_MISSING"
  )
end

-- A missing cursor PNG after the background was acquired must release the
-- background before raising.
function T.missing_cursor_asset_is_a_typed_error_and_releases_the_background()
  local cache = menuCache()
  cache:remove(FieldUiFixture.START_MENU_CURSOR_PATH)
  local lg = fakeGraphics({ imageSizes = { { 256, 192 } } })
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = cache, graphics = lg })
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_UI_START_MENU_CURSOR_MISSING",
    "raises FIELD_UI_START_MENU_CURSOR_MISSING"
  )
  Assert.equal(#lg.images, 1, "the background was acquired before the cursor failed")
  Assert.equal(lg.images[1].released, true, "the acquired background was released")
end

-- A quad failure after both images were created must release both before the
-- constructor rethrows.
function T.constructor_failure_releases_background_and_cursor()
  local lg = fakeGraphics({
    imageSizes = { { 256, 192 }, { 16, 32 } },
    failOnQuadCall = 2,
  })
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = menuCache(), graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil, "rethrows the quad failure")
  Assert.equal(#lg.images, 2, "background and cursor were created before the failure")
  Assert.equal(lg.images[1].released, true, "the background was released")
  Assert.equal(lg.images[2].released, true, "the cursor was released")
end

-- The renderer resolves the whole surface from the manifest's startMenu
-- section: background rect, the slot rects, the icon mapping, and the cursor
-- frames with their durations. The fixture's values are the only authority;
-- the renderer must not carry its own copy of the geometry.
function T.resolves_the_start_menu_section_from_the_manifest()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), graphics = lg })
  local manifest = FieldUiFixture.manifest().startMenu

  Assert.deepEqual(renderer.menu.background, manifest.background, "the background rect comes from the manifest")
  for id, rect in pairs(manifest.slots) do
    Assert.deepEqual(renderer.menu.slots[id], rect, "slot " .. id .. " comes from the manifest")
  end
  Assert.deepEqual(renderer.menu.icons, manifest.icons, "the icon mapping comes from the manifest")
  Assert.equal(#renderer.menu.cursor.frames, #manifest.cursor.frames, "every cursor frame is resolved")
  for index, frame in ipairs(manifest.cursor.frames) do
    Assert.deepEqual(renderer.menu.cursor.frames[index], frame, "cursor frame " .. index .. " comes from the manifest")
  end
  renderer:release()
end

-- A non-canonical manifest is resolved verbatim: a hard-coded canonical grid
-- would fail this test, which is what keeps the generated metadata the
-- authority (no source coordinates may be repeated in runtime code).
function T.the_manifest_geometry_is_the_authority_not_a_hard_coded_grid()
  local cache = menuCache()
  local manifest = FieldUiFixture.manifest()
  manifest.startMenu.slots = {
    [1] = { x = 10, y = 20, width = 100, height = 30 },
    [2] = { x = 120, y = 20, width = 100, height = 30 },
  }
  manifest.startMenu.cursor.frames = {
    { x = 0, y = 8, width = 8, height = 8, duration = 4 },
    { x = 8, y = 8, width = 8, height = 8, duration = 9 },
  }
  cache:writeLua("data/generated/field/ui/ui.lua", manifest)

  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = cache, graphics = lg })
  Assert.deepEqual(renderer.menu.slots[1], { x = 10, y = 20, width = 100, height = 30 })
  Assert.deepEqual(renderer.menu.slots[2], { x = 120, y = 20, width = 100, height = 30 })
  Assert.deepEqual(renderer.menu.cursor.frames[1], { x = 0, y = 8, width = 8, height = 8, duration = 4 })
  Assert.deepEqual(renderer.menu.cursor.frames[2], { x = 8, y = 8, width = 8, height = 8, duration = 9 })

  -- The cursor derives its placement from the manifest slot rect: centered
  -- over the presented slot, sized by the manifest frame rect.
  renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, canonicalViewport())
  local backgroundDraw = lg.draws[1]
  Assert.deepEqual(
    { backgroundDraw.quad.x, backgroundDraw.quad.y, backgroundDraw.quad.w, backgroundDraw.quad.h },
    { 0, 0, 256, 192 },
    "the background quad is the manifest background rect"
  )
  Assert.equal(backgroundDraw.x, 0)
  Assert.equal(backgroundDraw.y, 0)
  local cursorDraw = lg.draws[2]
  Assert.deepEqual(
    { cursorDraw.quad.x, cursorDraw.quad.y, cursorDraw.quad.w, cursorDraw.quad.h },
    { 0, 8, 8, 8 },
    "the cursor quad is the manifest frame rect"
  )
  Assert.equal(cursorDraw.x, 10 + 50 - 4, "the cursor centers on the slot x center")
  Assert.equal(cursorDraw.y, 20 + 15 - 4, "the cursor centers on the slot y center")
  renderer:release()
end

-- The canonical surface: background over the manifest rect, then the cursor
-- frame centered over the presented slot.
function T.draws_the_background_and_the_cursor_over_the_presented_slot()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), graphics = lg })
  renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, canonicalViewport())
  renderer:release()

  Assert.equal(#lg.draws, 2, "one background draw and one cursor draw")
  local backgroundDraw = lg.draws[1]
  Assert.equal(backgroundDraw.image, lg.images[1], "the background image is drawn first")
  Assert.deepEqual(
    { backgroundDraw.quad.x, backgroundDraw.quad.y, backgroundDraw.quad.w, backgroundDraw.quad.h },
    { 0, 0, 256, 192 }
  )
  Assert.equal(backgroundDraw.quad.imgW, 256, "the background quad samples the background atlas")
  Assert.equal(backgroundDraw.x, 0, "the background covers the manifest rect")
  Assert.equal(backgroundDraw.y, 0)

  local cursorDraw = lg.draws[2]
  Assert.equal(cursorDraw.image, lg.images[2], "the cursor image is drawn over the background")
  local slot = FieldUiFixture.START_MENU_SLOTS[1]
  Assert.equal(cursorDraw.x, slot.x + slot.width / 2 - 8, "the cursor centers on the presented slot")
  Assert.equal(cursorDraw.y, slot.y + slot.height / 2 - 8)
end

-- The presented frame index selects the manifest frame's quad: frame 0
-- samples the first atlas row, frame 1 the second (the fixture stacks the
-- two frames at y=0 and y=16).
function T.cursor_frame_index_selects_the_frame_quad()
  local function cursorQuad(frameIndex)
    local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
    local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), graphics = lg })
    renderer:draw({ cursorSlotId = 5, cursorFrameIndex = frameIndex }, canonicalViewport())
    renderer:release()
    return lg.draws[2].quad
  end
  Assert.deepEqual({ cursorQuad(0).x, cursorQuad(0).y }, { 0, 0 }, "frame 0 samples the first atlas row")
  Assert.deepEqual({ cursorQuad(1).x, cursorQuad(1).y }, { 0, 16 }, "frame 1 samples the second atlas row")
end

-- Slot ids and frame indexes are the manifest's key space: outside values
-- are programming faults, never silently clamped or dropped.
function T.rejects_unknown_slot_ids_and_frame_indexes()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), graphics = lg })
  Assert.throws(function()
    renderer:draw({ cursorSlotId = 0, cursorFrameIndex = 0 }, canonicalViewport())
  end, "slot 0 is outside the generated slot set")
  Assert.throws(function()
    renderer:draw({ cursorSlotId = 11, cursorFrameIndex = 0 }, canonicalViewport())
  end, "slot 11 is outside the generated slot set")
  Assert.throws(function()
    renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 2 }, canonicalViewport())
  end, "frame 2 is outside the generated frame set")
  renderer:release()
end

-- The Start Menu is not a generic list menu: the surface draws only the two
-- generated images at identity tint. No theme-colored rectangles, polygons,
-- or text primitives may appear.
function T.draws_only_the_generated_images_with_no_generic_menu_styling()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), graphics = lg })
  renderer:draw({ cursorSlotId = 3, cursorFrameIndex = 0 }, canonicalViewport())
  renderer:release()

  Assert.equal(#lg.primitives, 0, "no themed primitives are drawn")
  for _, call in ipairs(lg.draws) do
    Assert.isTrue(call.image == lg.images[1] or call.image == lg.images[2], "only the generated images are drawn")
    Assert.equal(call.color[1], 1, "draws happen at identity tint")
    Assert.equal(call.color[2], 1)
    Assert.equal(call.color[3], 1)
    Assert.equal(call.color[4], 1)
  end
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
    imageSizes = { { 256, 192 }, { 16, 32 } },
    failOnDrawCall = 2,
  })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), graphics = lg })

  local err = Assert.throws(function()
    renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, canonicalViewport())
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced after a failed draw")
  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
  renderer:release()
end

-- Release frees the owned images and clears the quads; a draw after release
-- is a no-op (with or without a presentation) and a second release is safe.
function T.release_frees_the_images_and_draw_after_release_is_a_noop()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), graphics = lg })
  renderer:release()
  renderer:release()

  Assert.isNil(renderer._backgroundImage)
  Assert.isNil(renderer._cursorImage)
  Assert.isNil(renderer._backgroundQuad)
  Assert.isNil(renderer._cursorQuads)
  renderer:draw(nil, canonicalViewport())
  renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, canonicalViewport())
  Assert.equal(#lg.draws, 0, "a released renderer draws nothing")
end

return { tests = T }
