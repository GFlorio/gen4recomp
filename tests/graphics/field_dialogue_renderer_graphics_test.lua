-- Graphics smoke tests for the dialogue renderer: the synthetic font atlas is
-- decoded into a real Image, the box is drawn at every host aspect, the frame
-- is rendered at canonical 256x192 and compared pixel-exact against an
-- independently composed reference for two frame styles (frame 0 and frame 1
-- of the fixture strip, mirroring the compiled class's distinct palettes),
-- and every graphics state the draw touched is proven restored against the
-- real driver. The construction/draw failure paths are injected fakes and
-- stay in field_dialogue_renderer_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldTextRenderer = require("libs.engine.src.FieldTextRenderer")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

local function renderer(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  return scope:own(FieldDialogueRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = FieldUiFixture.manifest(),
    text = text,
  }))
end

-- Steps a fixture dialogue until its text is fully revealed and the cursor
-- blink is off, so the canonical render is deterministic (text visible, no
-- cursor triangle).
---@param controller FieldDialogueController
local function settleDialogue(controller)
  controller:step({})
  for _ = 1, 4 do
    controller:step({})
  end
  for _ = 1, 31 do
    controller:step({})
  end
  local status = controller:status()
  Assert.equal(status.state, "WAITING_CLOSE")
  Assert.isFalse(status.cursorOn, "cursor blink is off in the settled render")
end

-- The canonical 256x192 render of the fixture dialogue for one frame style.
---@param scope GraphicsScope
---@param frameIndex integer
---@return love.ImageData
local function canonicalRender(scope, frameIndex)
  local lg = love.graphics
  local dialogue = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB", frameIndex)
  settleDialogue(controller)
  local viewport = FieldViewport.new(CANONICAL_WIDTH, CANONICAL_HEIGHT, { mode = "expanded" })
  local canvas = scope:own(lg.newCanvas(CANONICAL_WIDTH, CANONICAL_HEIGHT))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  dialogue:draw(controller, viewport)
  lg.setCanvas()
  return scope:own(canvas:newImageData())
end

-- The independent reference for the canonical render: the fixture's own tile
-- bytes placed by the pinned frame tilemap, plus the fixture font's two
-- glyphs at the layout text origin. Built without the renderer, so a draw
-- regression (wrong quad, wrong position, wrong frame row, wrong scale) is a
-- mismatch.
---@param frameIndex integer
---@return love.ImageData
local function goldenReference(frameIndex)
  local reference = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  local rgba = FieldUiFixture.framePixels(frameIndex)
  local placements = FieldDialogueTheme.frameTilePlacements(FieldDialogueTheme.box)
  local function paste(x, y, r, g, b, a)
    reference:setPixel(x, y, r, g, b, a)
  end
  for _, p in ipairs(placements) do
    for row = 0, (p.spanY or 1) - 1 do
      for col = 0, (p.spanX or 1) - 1 do
        for ty = 0, 7 do
          for tx = 0, 7 do
            local index = (ty * 144 + p.tile * 8 + tx) * 4 + 1
            paste(
              p.x + col * 8 + tx,
              p.y + row * 8 + ty,
              rgba:byte(index) / 255,
              rgba:byte(index + 1) / 255,
              rgba:byte(index + 2) / 255,
              rgba:byte(index + 3) / 255
            )
          end
        end
      end
    end
  end
  -- Text: glyph A (atlas columns 0..7, red) then glyph B (columns 8..15,
  -- green), both 8x16 at the layout text origin with advance 6.
  local layout = FieldDialogueTheme.layout({ x = 0, y = 0, width = CANONICAL_WIDTH, height = CANONICAL_HEIGHT })
  local glyphs = {
    { x = layout.text.x, red = true },
    { x = layout.text.x + 6, red = false },
  }
  for _, glyph in ipairs(glyphs) do
    for ty = 0, 15 do
      for tx = 0, 7 do
        if glyph.red then
          paste(glyph.x + tx, layout.text.y + ty, 200 / 255, 40 / 255, 40 / 255, 1)
        else
          paste(glyph.x + tx, layout.text.y + ty, 40 / 255, 200 / 255, 40 / 255, 1)
        end
      end
    end
  end
  return reference
end

-- Compares two ImageData buffers 8-bit channel by 8-bit channel; a single
-- differing pixel fails with its canonical coordinates.
local function assertPixelsEqual(expected, actual, label)
  Assert.equal(expected:getWidth(), actual:getWidth(), label .. " width")
  Assert.equal(expected:getHeight(), actual:getHeight(), label .. " height")
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local er, eg, eb, ea = expected:getPixel(x, y)
      local ar, ag, ab, aa = actual:getPixel(x, y)
      if
        quantize(er) ~= quantize(ar)
        or quantize(eg) ~= quantize(ag)
        or quantize(eb) ~= quantize(ab)
        or quantize(ea) ~= quantize(aa)
      then
        error(
          string.format(
            "%s: pixel mismatch at (%d,%d): expected (%d,%d,%d,%d) got (%d,%d,%d,%d)",
            label,
            x,
            y,
            quantize(er),
            quantize(eg),
            quantize(eb),
            quantize(ea),
            quantize(ar),
            quantize(ag),
            quantize(ab),
            quantize(aa)
          )
        )
      end
    end
  end
end

function T.loads_the_shared_font_atlas_and_own_frame_strip(scope)
  local dialogue = renderer(scope)

  Assert.equal(dialogue._text.fontDef.schema, "g4-field-font-v1")
  Assert.notNil(dialogue._text._atlas)
  Assert.equal(dialogue._text._atlas:getWidth(), 16)
  Assert.notNil(dialogue._frameImage, "the generated frame strip is loaded")
  Assert.equal(dialogue._frameImage:getWidth(), 144)
end

function T.restores_graphics_state_after_draw(scope)
  local lg = love.graphics
  local dialogue = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB")
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })

  local canvas = scope:own(lg.newCanvas(64, 64))
  local shader = lg.getShader()
  lg.setCanvas(canvas)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  dialogue:draw(controller, viewport)

  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
end

function T.a_closed_controller_draws_nothing_and_changes_no_state(scope)
  local lg = love.graphics
  local dialogue = renderer(scope)
  local controller = FieldDialogueController.new({
    layout = function()
      return { pages = {}, warnings = {} }
    end,
  })

  lg.setColor(0.1, 0.2, 0.3, 0.4)
  dialogue:draw(controller, FieldViewport.new(960, 720, { mode = "expanded" }))

  Assert.near(lg.getColor(), 0.1, 1e-6)
  Assert.isNil(lg.getShader())
end

function T.draws_inside_the_reference_frame_at_every_host_aspect(scope)
  local dialogue = renderer(scope)

  for _, size in ipairs({ { 960, 720 }, { 1280, 720 }, { 1920, 720 }, { 640, 480 } }) do
    local controller = FieldDialogueFixture.openDialogue("AB", 0)
    local viewport = FieldViewport.new(size[1], size[2], { mode = "expanded" })
    dialogue:draw(controller, viewport)

    -- Layout geometry stays in reference-canvas coordinates (the draw
    -- applies the single origin+scale transform), so the box must fit the
    -- reference canvas at every host aspect.
    local layout = FieldDialogueTheme.layout(viewport.referenceFrame)
    local box = layout.box
    Assert.isTrue(box.x >= 0, "box in reference space at " .. size[1] .. "x" .. size[2])
    Assert.isTrue(box.x + box.width <= FieldDialogueTheme.referenceWidth + 1e-9)
    Assert.isTrue(box.y >= 0 and box.y + box.height <= FieldDialogueTheme.referenceHeight + 1e-9)
  end
end

-- Canonical golden: the frame 0 render matches the independent reference
-- pixel for pixel. The frame tilemap fills the 256x192 canvas around the
-- content rect; the content stays transparent and the text sits at the
-- layout origin.
function T.canonical_golden_matches_frame_zero_pixel_for_pixel(scope)
  local rendered = canonicalRender(scope, 0)
  assertPixelsEqual(goldenReference(0), rendered, "frame 0 golden")
end

-- Canonical golden: frame 1 selects a different strip row, so the artwork
-- changes while the content geometry (transparent content rect, text at the
-- same origin) stays identical.
function T.canonical_golden_matches_frame_one_pixel_for_pixel(scope)
  local lg = love.graphics
  local frame0 = canonicalRender(scope, 0)
  local frame1 = canonicalRender(scope, 1)
  assertPixelsEqual(goldenReference(1), frame1, "frame 1 golden")

  -- The frame region differs (different palette), the content rect is
  -- transparent in both, and the text pixels are identical.
  local quantize = function(v)
    return math.floor(v * 255 + 0.5)
  end
  local function pixel(data, x, y)
    local r, g, b, a = data:getPixel(x, y)
    return quantize(r), quantize(g), quantize(b), quantize(a)
  end
  local f0r, f0g, f0b = pixel(frame0, 0, 144)
  local f1r, f1g, f1b = pixel(frame1, 0, 144)
  Assert.isTrue(f0r ~= f1r or f0g ~= f1g or f0b ~= f1b, "frame styles have distinct artwork")

  local box = FieldDialogueTheme.box
  for _, frame in ipairs({ frame0, frame1 }) do
    local r, g, b, a = pixel(frame, box.x + box.width / 2, box.y + box.height / 2)
    Assert.equal(a, 0, "the content rect stays transparent")
    Assert.equal(r, 0)
    Assert.equal(g, 0)
    Assert.equal(b, 0)
  end

  local ta0r, ta0g, ta0b, ta0a = frame0:getPixel(26, 152)
  local ta1r, ta1g, ta1b, ta1a = frame1:getPixel(26, 152)
  Assert.equal(quantize(ta0r), quantize(ta1r), "text pixels identical across frames")
  Assert.equal(quantize(ta0g), quantize(ta1g))
  Assert.equal(quantize(ta0b), quantize(ta1b))
  Assert.equal(quantize(ta0a), quantize(ta1a))
  Assert.equal(quantize(ta0r), 200, "the first glyph renders at the layout origin")
end

-- Release is the contract here; it is still scoped so a failed assertion does
-- not leak the renderer. The scope's later release exercises repeat safety.
function T.release_frees_the_owned_frame_strip(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local dialogue = scope:own(FieldDialogueRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = FieldUiFixture.manifest(),
    text = text,
  }))

  dialogue:release()

  Assert.isNil(dialogue._frameImage)
end

return GraphicsSmoke.suite(T)
