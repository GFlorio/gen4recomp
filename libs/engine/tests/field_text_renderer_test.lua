-- Color-band and focus-indicator presentation contracts for the shared
-- FieldTextRenderer, driven through the shared FakeGraphics namespace: glyph
-- quads must sample the color band named by the token's prepared colorIndex
-- (variant y = glyph.y + colorIndex * colorVariants.strideY), built lazily
-- per color; plain drawText stays on color 0 and color never changes glyph
-- advance or measured width; the focus-indicator strip is renderer-owned and
-- drawFocusIndicator(field, x, y) selects the imported frame rect at the
-- caller's position without deciding placement; out-of-range color indices
-- and focus fields fail loudly instead of clamping; release frees every owned
-- image exactly once. These tests use the shared fake, so the base-band-tall
-- fixture PNGs are never decoded.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldTextRenderer = require("libs.engine.src.FieldTextRenderer")

local T = {}

-- The fake graphics namespace records every draw and created image; the
-- shared helper is tests/support/FakeGraphics.lua. Image sizes: the glyph
-- atlas (16px-wide base band) and the 96x32 focus-indicator strip, in the
-- order the ready font bundle's assets are acquired.
local fakeGraphics = require("tests.support.FakeGraphics").new

local function textRenderer(lg)
  return FieldTextRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = lg })
end

local function glyphToken(code, colorIndex)
  return { kind = "glyph", code = code, text = "x", raw = { code }, colorIndex = colorIndex }
end

-- The fixture font: baseHeight 16, strideY 16, every glyph rect at y=0 with
-- advance 6 (code 1/2) or 4 (code 0).
local function strideY()
  return FieldDialogueFixture.fontDef().colorVariants.strideY
end

-- The full-height atlas image the fake supplies (the fixture PNG is only
-- base-band tall and is never decoded by the fake).
local function atlasImageSize()
  local def = FieldDialogueFixture.fontDef()
  return { def.atlas.width, def.atlas.height }
end

-- A colored glyph token must sample the color band named by its
-- prepared colorIndex: variant y = glyph.y + colorIndex * strideY.
function T.colored_glyph_quads_select_their_color_band()
  local lg = fakeGraphics({ imageSizes = { atlasImageSize(), { 96, 32 } } })
  local text = textRenderer(lg)
  local stride = strideY()
  for _, colorIndex in ipairs({ 0, 1, 6 }) do
    text:drawLine({ glyphToken(1, colorIndex) }, 10, 20)
    local call = lg.draws[#lg.draws]
    Assert.equal(call.quad.y, 0 + colorIndex * stride, "color " .. colorIndex .. " samples its band")
  end
  text:release()
end

-- Color carries no width; drawing the same glyphs in two colors must
-- produce identical x advances (only the sampled band differs).
function T.drawing_the_same_text_in_two_colors_preserves_x_advances()
  local function coloredXs(colorIndex)
    local lg = fakeGraphics({ imageSizes = { atlasImageSize(), { 96, 32 } } })
    local text = textRenderer(lg)
    text:drawLine({ glyphToken(2, colorIndex), glyphToken(1, colorIndex) }, 0, 0)
    text:release()
    return { lg.draws[1].x, lg.draws[2].x }
  end
  Assert.deepEqual(coloredXs(6), coloredXs(0), "the color variant never changes the x advances")
end

-- Plain drawText stays on color 0 (the base band), so unstyled callers
-- like the Trainer Card are visually unchanged.
function T.plain_draw_text_stays_on_color_zero()
  local lg = fakeGraphics({ imageSizes = { atlasImageSize(), { 96, 32 } } })
  local text = textRenderer(lg)
  text:drawText("A", 4, 8)
  Assert.equal(#lg.draws, 1)
  Assert.equal(lg.draws[1].quad.y, 0, "drawText never leaves the base band")
  text:release()
end

-- drawFocusIndicator() selects the imported frame rect of the requested
-- field and draws it at exactly the caller's position; the method owns no
-- placement decision.
function T.draw_focus_indicator_selects_the_requested_frame_rect()
  local lg = fakeGraphics({ imageSizes = { atlasImageSize(), { 96, 32 } } })
  local text = textRenderer(lg)
  for field = 0, 3 do
    text:drawFocusIndicator(field, 200 + field, 152)
    local call = lg.draws[#lg.draws]
    Assert.equal(call.quad.x, field * 24, "field " .. field .. " samples its own strip rect")
    Assert.equal(call.quad.y, 0)
    Assert.equal(call.quad.w, 24, "the indicator frame is 24px wide")
    Assert.equal(call.quad.h, 32, "the indicator frame is 32px tall")
    Assert.equal(call.x, 200 + field, "the caller's x is passed through")
    Assert.equal(call.y, 152, "the caller's y is passed through")
  end
  text:release()
end

-- A color index outside 0..6 must fail loudly, never silently clamp to
-- color 0.
function T.invalid_color_indices_fail_loudly()
  local lg = fakeGraphics({ imageSizes = { atlasImageSize(), { 96, 32 } } })
  local text = textRenderer(lg)
  for _, bad in ipairs({ -1, 7 }) do
    Assert.throws(function()
      text:drawLine({ glyphToken(1, bad) }, 0, 0)
    end, "color index " .. tostring(bad) .. " must raise, never clamp to color 0")
  end
  text:release()
end

-- A focus field outside 0..3 must fail loudly with a typed error.
function T.invalid_focus_fields_fail_loudly()
  local lg = fakeGraphics({ imageSizes = { atlasImageSize(), { 96, 32 } } })
  local text = textRenderer(lg)
  for _, bad in ipairs({ -1, 4 }) do
    local err = Assert.throws(function()
      text:drawFocusIndicator(bad, 0, 0)
    end, "focus field " .. tostring(bad) .. " must raise")
    Assert.isTrue(Errors.is(err), "the invalid focus field raises a typed error")
  end
  text:release()
end

-- A cache without the focus-indicator PNG must not build a half renderer:
-- the typed error names the missing artifact before any image is created.
function T.missing_focus_image_is_a_typed_error()
  local cache = FieldDialogueFixture.cacheWithFont()
  cache:remove(FieldDialogueFixture.FOCUS_INDICATOR_PATH)
  local lg = fakeGraphics({ imageSizes = { atlasImageSize() } })
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = cache, graphics = lg })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FONT_FOCUS_IMAGE_MISSING", "raises FONT_FOCUS_IMAGE_MISSING")
  Assert.equal(#lg.images, 0, "no image was created before the focus strip read failed")
end

-- A focus-strip creation failure after the glyph atlas exists must release
-- the acquired atlas before the constructor rethrows.
function T.focus_image_failure_releases_the_acquired_atlas()
  local lg = fakeGraphics({ imageSizes = { atlasImageSize(), { 96, 32 } }, failOnImageCall = 2 })
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newImage failure", 1, true) ~= nil, "rethrows the image failure")
  Assert.equal(#lg.images, 1, "the glyph atlas was created before the failure")
  Assert.equal(lg.images[1].released, true, "the acquired atlas was released")
end

-- Releasing the shared text renderer releases every image it owns (the
-- glyph atlas and the focus-indicator strip) exactly once; a second release
-- is safe.
function T.release_releases_every_owned_image_exactly_once()
  local lg = fakeGraphics({ imageSizes = { atlasImageSize(), { 96, 32 } } })
  local text = textRenderer(lg)
  Assert.isTrue(#lg.images == 2, "the renderer owns the glyph atlas and the focus-indicator image")
  text:release()
  for index, image in ipairs(lg.images) do
    Assert.isTrue(image.released, "owned image " .. index .. " is released")
  end
  text:release()
  Assert.isTrue(lg.images[1].released, "releasing twice is safe")
end

return { tests = T }
