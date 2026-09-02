-- Field font definitions are runtime data. Loading them must not allocate a
-- presentation resource, so field composition can lay out dialogue before a
-- renderer exists. The loader must also reject a malformed or stale v1
-- definition before presentation construction, so a pre-change cache cannot
-- pass through the new color-band and focus-indicator contract.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldMessageText = require("libs.assets.src.FieldMessageText")

local T = {}

local COLOR_COUNT = FieldMessageText.COLOR_VARIANT_COUNT
local FOCUS_COUNT = FieldMessageText.FOCUS_INDICATOR_COUNT

local function validDef(fontId)
  fontId = fontId or 0
  local baseHeight = 16
  return {
    schema = FieldFontCache.SCHEMA,
    fontId = fontId,
    maskAtlasPath = FieldFontCache.maskAtlasPath(fontId),
    lineHeight = 16,
    maxLetterHeight = 16,
    letterSpacing = 0,
    glyphCount = 1,
    fallbackCode = 0,
    atlas = {
      width = 1024,
      height = baseHeight * COLOR_COUNT,
      baseHeight = baseHeight,
      glyphsPerRow = 64,
      glyphWidth = 16,
      glyphHeight = 16,
    },
    colorVariants = { count = COLOR_COUNT, strideY = baseHeight },
    focusIndicators = {
      imagePath = FieldFontCache.focusIndicatorsPath(fontId),
      count = FOCUS_COUNT,
      width = 24,
      height = 32,
      frames = {
        [0] = { x = 0, y = 0, width = 24, height = 32 },
        [1] = { x = 24, y = 0, width = 24, height = 32 },
        [2] = { x = 48, y = 0, width = 24, height = 32 },
        [3] = { x = 72, y = 0, width = 24, height = 32 },
      },
    },
    glyphs = {
      [0] = { x = 0, y = 0, w = 16, h = 16, advance = 6, bearingX = 0, bearingY = 0 },
    },
    charmap = {},
    palette = {},
  }
end

local function cacheWith(def, fontId)
  fontId = fontId or def.fontId
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldFontCache.defPath(fontId), def)
  return cache
end

local function loadExpectRaised(def, context)
  local raised = Assert.throws(function()
    FieldFontLoader.load(cacheWith(def))
  end, context)
  Assert.isTrue(Errors.is(raised), context .. " must be a typed error")
end

function T.loads_the_compiled_definition_without_a_graphics_namespace()
  local definition = validDef()
  local loaded = FieldFontLoader.load(cacheWith(definition)) --[[@as table]]
  Assert.deepEqual(loaded, definition)
  Assert.equal(loaded.colorVariants.count, FieldMessageText.COLOR_VARIANT_COUNT)
  Assert.equal(loaded.focusIndicators.count, FieldMessageText.FOCUS_INDICATOR_COUNT)
end

function T.loads_font_four_from_its_parameterized_definition_path()
  local definition = validDef(4)
  local loaded = FieldFontLoader.load(cacheWith(definition), 4) --[[@as table]]
  Assert.deepEqual(loaded, definition)
  Assert.equal(loaded.fontId, 4)
end

function T.load_rejects_a_wrong_color_variant_count()
  local definition = validDef()
  assert(definition.colorVariants)
  definition.colorVariants.count = FieldMessageText.COLOR_VARIANT_COUNT - 1
  loadExpectRaised(definition, "a count that does not match the protocol color count must be rejected")
end

function T.load_rejects_a_non_positive_color_stride()
  local definition = validDef()
  assert(definition.colorVariants)
  definition.colorVariants.strideY = 0
  loadExpectRaised(definition, "a non-positive color stride must be rejected")
end

function T.load_rejects_an_atlas_too_short_for_the_color_bands()
  local definition = validDef()
  definition.atlas.height = definition.atlas.baseHeight * FieldMessageText.COLOR_VARIANT_COUNT - 1
  loadExpectRaised(definition, "an atlas too short for all color bands must be rejected")
end

-- The v3 contract requires a named semantic glyph mask atlas; a missing or
-- empty path is rejected before presentation construction.
function T.load_rejects_a_missing_mask_atlas_path()
  local definition = validDef()
  definition.maskAtlasPath = nil
  loadExpectRaised(definition, "a definition without maskAtlasPath must be rejected")
  local empty = validDef()
  empty.maskAtlasPath = ""
  loadExpectRaised(empty, "an empty maskAtlasPath must be rejected")
end

-- A stale pre-v3 definition (no maskAtlasPath at all, as a real v2 font
-- definition would be) must never pass through as if it were current.
function T.load_rejects_a_stale_v2_definition()
  local v2 = validDef()
  v2.schema = "g4-field-font-v2"
  v2.maskAtlasPath = nil
  loadExpectRaised(v2, "a stale v2 definition must be rejected")
end

function T.load_rejects_wrong_focus_count_and_rect_geometry()
  for _, count in ipairs({ FieldMessageText.FOCUS_INDICATOR_COUNT - 1, FieldMessageText.FOCUS_INDICATOR_COUNT + 1 }) do
    local definition = validDef()
    definition.focusIndicators.count = count
    loadExpectRaised(definition, "a focus count that does not match the protocol must be rejected")
  end
  local noFrames = validDef()
  noFrames.focusIndicators.frames = nil
  loadExpectRaised(noFrames, "missing focus frame rects must be rejected")
  local badRect = validDef()
  badRect.focusIndicators.frames[0].width = 23
  loadExpectRaised(badRect, "a focus rect that is not exactly 24x32 must be rejected")
end

return { tests = T }
