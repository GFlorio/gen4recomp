-- Compiles the HGSS field font (font 0) into a private glyph atlas PNG, a
-- semantic glyph mask atlas PNG, a focus-indicator PNG, and the
-- g4-field-font-v3 definition. The mask atlas repeats the composited atlas's
-- base-band glyph geometry once, encoding each glyph pixel's raw 0..3 class
-- categorically (0 transparent, 1 red foreground, 2 green shadow, 3 blue
-- background) instead of a baked color, so a palette-driven draw path can
-- recolor glyphs against any runtime palette. Glyph tiles and
-- the width table come from NARC_graphic_font member 0 (src/font_data.c); the
-- screen-focus indicator set the YESNO printer control blits comes from member
-- 6 (the GfGfxLoader_GetCharData payload, decoded as NCGR char data); colors
-- come from the RLCN-wrapped TTLP palette member 7 (src/font.c LoadFontPal0).
-- Glyph pixel values map to palette slots via GenerateFontHalfRowLookupTable
-- (src/text.c): 0 = transparent, 1 = foreground, 2 = shadow, 3 = background.
-- Each color variant resolves one foreground/shadow palette pair (slots 2n+1
-- and 2n+2 for color n; slot 15 stays the field-window background), so the
-- atlas stacks COLOR_VARIANT_COUNT bands of the base glyph geometry.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldFontDecoder = require("romdump.src.digest.FieldFontDecoder")
local G2dDecoder = require("romdump.src.digest.G2dDecoder")
local FieldMessageCompiler = require("romdump.src.digest.FieldMessageCompiler")
local charmap = require("romdump.src.reference.hgss.charmap")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldMessageText = require("libs.assets.src.FieldMessageText")
local manifest = require("romdump.src.config.FieldMessages")

local FieldFontCompiler = {}

local GLYPH_SIZE = 16
local FOCUS_FRAME_WIDTH = FieldFontCache.FOCUS_FRAME_WIDTH
local FOCUS_FRAME_HEIGHT = FieldFontCache.FOCUS_FRAME_HEIGHT
local FOCUS_TILES_PER_FRAME = math.floor(FOCUS_FRAME_WIDTH / 8) * math.floor(FOCUS_FRAME_HEIGHT / 8)

-- Categorical (never colorimetric) encoding of one raw glyph pixel value for
-- the semantic mask atlas: 0 transparent, 1 foreground (red marker), 2 shadow
-- (green marker), 3 background (blue marker). A palette-driven draw path
-- reads these exact channels, never a fuzzy RGB match.
---@param value integer
---@return integer, integer, integer, integer
local function glyphMaskRgba(value)
  if value == 0 then
    return 0, 0, 0, 0
  elseif value == 1 then
    return 255, 0, 0, 255
  elseif value == 2 then
    return 0, 255, 0, 255
  elseif value == 3 then
    return 0, 0, 255, 255
  end
  error("glyph mask value outside 0..3")
end

local function must(value, err)
  if value == nil then
    error(err)
  end
  return value
end

local function loadSource(romFs, sha1hex)
  local archiveInfo = romFs:resolvedNarc("font")
  if not archiveInfo then
    Errors.raise("ROMFS_NARC_UNRESOLVED", "font NARC is unavailable", { name = "font" })
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc("font"))
  return {
    archive = archive,
    archiveInfo = archiveInfo,
    archiveSha1 = sha1hex(archiveBytes),
  }
end

-- Composite-atlas pixel mapping for one color band: 0 = transparent,
-- 1 = the band's foreground ink, 2 = the band's shadow, 3 = the font's
-- background slot. Band n resolves source values 1/2 to palette slots 2n+1
-- and 2n+2, so band 0 keeps the font's default sFontInfos[0] pair
-- (fgColor = 0x01, shadowColor = 0x02) from src/font.c applied through
-- GenerateFontHalfRowLookupTable (src/text.c); palette.colors is 1-based
-- (colors[i] = slot i-1), so the index is slot + 1. The DS drew the
-- background slot in the window fill color so it *looked* transparent; in a
-- composited atlas it must be actually transparent ("transparent glyph
-- background"), otherwise every 16x16 glyph cell becomes an opaque rectangle
-- that chops the narrower glyphs placed before it.

---@param value integer
---@param palette FieldFontDecoder.Palette
---@param colorVariant integer
---@return integer, integer, integer, integer
local function pixelToRgba(value, palette, colorVariant)
  if value == 0 or value == 3 then
    return 0, 0, 0, 0
  end
  local slot
  if value == 1 then
    slot = colorVariant * 2 + FieldFontDecoder.FG_PALETTE_INDEX
  else
    slot = colorVariant * 2 + FieldFontDecoder.SHADOW_PALETTE_INDEX
  end
  local color = palette[slot + 1]
  assert(color ~= nil, "color variant " .. colorVariant .. " needs palette slot " .. slot)
  return color.r, color.g, color.b, 255
end

---@param romFs RomFs
---@param source { archive: RomFs.Narc, archiveInfo: RomFs.NarcInfo, archiveSha1: string }
---@param sha1hex fun(bytes: string): string
---@param hashLua fun(value: any): string
---@return FieldFontCompiler.Bundle
local function compileFont(romFs, source, sha1hex, hashLua)
  local fontId = manifest.fontId
  local glyphMember = must(source.archive:readMember(manifest.fontGlyphMember))
  local focusMember = must(source.archive:readMember(manifest.fontFocusIndicatorMember))
  local paletteMember = must(source.archive:readMember(manifest.fontPaletteMember))
  local glyphSha1 = sha1hex(glyphMember)
  local focusSha1 = sha1hex(focusMember)
  local paletteSha1 = sha1hex(paletteMember)

  local font = must(FieldFontDecoder.decodeMember(glyphMember, {
    label = "field-font-glyphs",
  }))
  local palette = must(FieldFontDecoder.decodePalette(paletteMember, {
    label = "field-font-palette",
  }))
  if palette.colorCount < 16 then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "font palette has " .. palette.colorCount .. " colors, need at least 16",
      { colorCount = palette.colorCount }
    )
  end

  -- The focus-indicator set is 4bpp NCGR char data (the member the source
  -- loads through GfGfxLoader_GetCharData); the shape must be exactly
  -- FOCUS_INDICATOR_COUNT 24x32 frames, so a wrong payload is a format error,
  -- never a partial/garbage indicator set.
  local focusChars = must(G2dDecoder.decodeChar(focusMember, {
    label = "field-font-focus-indicators",
  }))
  local focusTiles = math.floor(#focusChars.tiles / 32)
  local expectedTiles = FieldMessageText.FOCUS_INDICATOR_COUNT * FOCUS_TILES_PER_FRAME
  if focusChars.depth ~= 3 or focusTiles ~= expectedTiles then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "font focus member holds "
        .. focusChars.depth
        .. "-bpp char data with "
        .. focusTiles
        .. " tiles, need 4bpp with exactly "
        .. expectedTiles,
      { depth = focusChars.depth, tiles = focusTiles, expectedTiles = expectedTiles }
    )
  end

  local function concatRgba(chars)
    -- string.char/unpack are limited by the Lua stack; build in row chunks.
    local out = {}
    for i = 1, #chars, 4096 do
      out[#out + 1] = string.char(unpack(chars, i, math.min(i + 4095, #chars)))
    end
    return table.concat(out)
  end

  local perRow = manifest.atlasGlyphsPerRow
  local rows = math.ceil(font.numGlyphs / perRow)
  local width = perRow * GLYPH_SIZE
  local baseHeight = rows * GLYPH_SIZE
  local variantCount = FieldMessageText.COLOR_VARIANT_COUNT
  local height = baseHeight * variantCount

  local glyphPixels = {}
  for glyphIndex = 0, font.numGlyphs - 1 do
    glyphPixels[glyphIndex + 1] = font.glyphPixels(glyphIndex)
  end

  -- One stacked band per color index; each band repeats the base glyph
  -- geometry exactly, only the foreground/shadow palette pair differs.
  local rgba = {}
  for i = 1, width * height * 4 do
    rgba[i] = 0
  end
  for colorVariant = 0, variantCount - 1 do
    local variantBaseY = colorVariant * baseHeight
    for glyphIndex = 0, font.numGlyphs - 1 do
      local glyph = glyphPixels[glyphIndex + 1]
      local baseX = (glyphIndex % perRow) * GLYPH_SIZE
      local baseY = variantBaseY + math.floor(glyphIndex / perRow) * GLYPH_SIZE
      for y = 0, 15 do
        for x = 0, 15 do
          local r, g, b, a = pixelToRgba(glyph.values[y + 1][x + 1], palette.colors, colorVariant)
          local offset = ((baseY + y) * width + baseX + x) * 4
          rgba[offset + 1] = r
          rgba[offset + 2] = g
          rgba[offset + 3] = b
          rgba[offset + 4] = a
        end
      end
    end
  end
  local atlasBytes = PngWriter.encode(width, height, concatRgba(rgba))

  -- The semantic glyph mask atlas: one copy of the base glyph geometry (no
  -- stacked color bands -- glyph class is source-fixed, not color-band
  -- dependent) encoding the raw 0..3 pixel value categorically rather than
  -- colorimetrically, so a palette-driven draw path can recover which class
  -- each pixel belongs to regardless of any baked RGB.
  local maskRgba = {}
  for i = 1, width * baseHeight * 4 do
    maskRgba[i] = 0
  end
  for glyphIndex = 0, font.numGlyphs - 1 do
    local glyph = glyphPixels[glyphIndex + 1]
    local baseX = (glyphIndex % perRow) * GLYPH_SIZE
    local baseY = math.floor(glyphIndex / perRow) * GLYPH_SIZE
    for y = 0, 15 do
      for x = 0, 15 do
        local r, g, b, a = glyphMaskRgba(glyph.values[y + 1][x + 1])
        local offset = ((baseY + y) * width + baseX + x) * 4
        maskRgba[offset + 1] = r
        maskRgba[offset + 2] = g
        maskRgba[offset + 3] = b
        maskRgba[offset + 4] = a
      end
    end
  end
  local maskAtlasBytes = PngWriter.encode(width, baseHeight, concatRgba(maskRgba))

  -- Indicator frames composite from the same palette: pixel value 0 is the
  -- shape's empty background (and the field-window background slot stays
  -- transparent, mirroring the glyph atlas), every other value keeps its
  -- source palette slot. Frames are packed left-to-right by source field
  -- index; the frames table below makes the packing explicit.
  local focusImageWidth = FOCUS_FRAME_WIDTH * FieldMessageText.FOCUS_INDICATOR_COUNT
  local focusRgba = {}
  for i = 1, focusImageWidth * FOCUS_FRAME_HEIGHT * 4 do
    focusRgba[i] = 0
  end
  local function focusPixel(field, x, y)
    local intraX = x % FOCUS_FRAME_WIDTH
    local tileIndex = field * FOCUS_TILES_PER_FRAME
      + math.floor(y / 8) * math.floor(FOCUS_FRAME_WIDTH / 8)
      + math.floor(intraX / 8)
    local byte = focusChars.tiles:byte(tileIndex * 32 + (y % 8) * 4 + math.floor((intraX % 8) / 2) + 1)
    -- 4bpp tile bytes hold two pixels with the LEFT (even) pixel in the low
    -- nibble (GBATEK "Nitro Character Tiles"), the same convention as
    -- FieldUiCompiler.blitTile; a swapped read mirrors every 2px group.
    if intraX % 2 == 0 then
      return byte % 16
    end
    return math.floor(byte / 16)
  end
  for field = 0, FieldMessageText.FOCUS_INDICATOR_COUNT - 1 do
    for y = 0, FOCUS_FRAME_HEIGHT - 1 do
      for x = 0, FOCUS_FRAME_WIDTH - 1 do
        local value = focusPixel(field, x, y)
        local r, g, b, a = 0, 0, 0, 0
        if value ~= 0 and value ~= FieldFontDecoder.BG_PALETTE_INDEX then
          local color = palette.colors[value + 1]
          assert(color ~= nil, "focus indicator needs palette slot " .. value)
          r, g, b, a = color.r, color.g, color.b, 255
        end
        local offset = ((field * FOCUS_FRAME_WIDTH + x) + y * focusImageWidth) * 4
        focusRgba[offset + 1] = r
        focusRgba[offset + 2] = g
        focusRgba[offset + 3] = b
        focusRgba[offset + 4] = a
      end
    end
  end
  local focusIndicators = {
    imagePath = FieldFontCache.focusIndicatorsPath(fontId),
    count = FieldMessageText.FOCUS_INDICATOR_COUNT,
    width = FOCUS_FRAME_WIDTH,
    height = FOCUS_FRAME_HEIGHT,
    frames = {},
  }
  for field = 0, FieldMessageText.FOCUS_INDICATOR_COUNT - 1 do
    focusIndicators.frames[field] = {
      x = field * FOCUS_FRAME_WIDTH,
      y = 0,
      width = FOCUS_FRAME_WIDTH,
      height = FOCUS_FRAME_HEIGHT,
    }
  end
  local focusIndicatorsBytes = PngWriter.encode(focusImageWidth, FOCUS_FRAME_HEIGHT, concatRgba(focusRgba))

  local glyphs = {}
  local function quad(glyphIndex)
    local col = glyphIndex % perRow
    local row = math.floor(glyphIndex / perRow)
    return {
      x = col * GLYPH_SIZE,
      y = row * GLYPH_SIZE,
      w = font.fixedWidth,
      h = font.fixedHeight,
      advance = font.glyphWidth(glyphIndex),
      bearingX = 0,
      bearingY = 0,
    }
  end
  for code = 1, font.numGlyphs do
    glyphs[code] = quad(font.glyphIndexForCode(code))
  end
  glyphs[0] = quad(FieldFontDecoder.FALLBACK_GLYPH_INDEX)

  -- Text encoding metadata: every single-character display text -> code unit
  -- mapping from the frozen charmap reference, so runtime substitution text
  -- can be converted without importing the reference itself.
  local function isSingleCharacter(text)
    -- UTF-8: one character = one leading byte plus continuation bytes.
    local sequences = 0
    for i = 1, #text do
      local byte = text:byte(i)
      if byte < 0x80 or byte >= 0xC0 then
        sequences = sequences + 1
      end
    end
    return sequences == 1
  end
  local textToCode = {}
  for code, text in pairs(charmap.glyphs) do
    if isSingleCharacter(text) then
      assert(textToCode[text] == nil, "charmap maps multiple codes to the single character " .. text)
      textToCode[text] = code
    end
  end

  local fontDef = {
    schema = FieldFontCache.SCHEMA,
    fontId = fontId,
    atlasPath = FieldFontCache.atlasPath(fontId),
    maskAtlasPath = FieldFontCache.maskAtlasPath(fontId),
    lineHeight = font.fixedHeight,
    maxLetterHeight = font.fixedHeight,
    letterSpacing = 0,
    glyphCount = font.numGlyphs,
    fallbackCode = 0,
    atlas = {
      width = width,
      height = height,
      baseHeight = baseHeight,
      glyphsPerRow = perRow,
      glyphWidth = GLYPH_SIZE,
      glyphHeight = GLYPH_SIZE,
    },
    colorVariants = {
      count = variantCount,
      strideY = baseHeight,
    },
    focusIndicators = focusIndicators,
    glyphs = glyphs,
    charmap = textToCode,
    palette = palette.colors,
  }

  local dependencies = {
    cacheFormat = FieldFontCache.FORMAT,
    charmapVersion = FieldMessageCompiler.CHARMAP_VERSION,
    manifestSchema = manifest.schema,
    versionRomSha1 = romFs:metadata().sha1,
    fontNarc = {
      symbol = source.archiveInfo.symbol,
      alias = source.archiveInfo.alias,
      narcId = source.archiveInfo.narcId,
      fileId = source.archiveInfo.fileId,
      path = source.archiveInfo.path,
      sha1 = source.archiveSha1,
    },
    glyphMemberId = manifest.fontGlyphMember,
    glyphMemberSha1 = glyphSha1,
    focusIndicatorMemberId = manifest.fontFocusIndicatorMember,
    focusIndicatorMemberSha1 = focusSha1,
    paletteMemberId = manifest.fontPaletteMember,
    paletteMemberSha1 = paletteSha1,
  }

  local marker = FieldFontCache.marker(romFs:metadata().sha1, hashLua(dependencies))
  return {
    fontId = fontId,
    marker = marker,
    font = fontDef,
    atlas = atlasBytes,
    maskAtlas = maskAtlasBytes,
    focusIndicators = focusIndicatorsBytes,
    dependencies = dependencies,
  }
end

---@param romFs RomFs
---@param sha1hex fun(bytes: string): string?
---@param hashLua fun(value: any): string?
---@return FieldFontCompiler.Bundle
local function _compile(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  return compileFont(romFs, loadSource(romFs, sha1hex), sha1hex, hashLua)
end

---@param romFs RomFs
---@param sha1hex? fun(bytes: string): string|nil
---@param hashLua? fun(value: any): string|nil
---@return FieldFontCompiler.Bundle?
---@return Errors.Error?
function FieldFontCompiler.compile(romFs, sha1hex, hashLua)
  local ok, result = pcall(_compile, romFs, sha1hex, hashLua)
  if ok then
    return result, nil
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

-- The compiled font class: the g4-field-font-v3 definition, the glyph atlas
-- PNG, the semantic glyph mask atlas PNG, the focus-indicator PNG, and the
-- cache marker derived from every source dependency.

---@class FieldFontCompiler.Bundle
---@field fontId integer
---@field marker string
---@field font FieldFontDef
---@field atlas string
---@field maskAtlas string
---@field focusIndicators string
---@field dependencies table

-- The g4-field-font-v3 runtime definition consumed by the dialogue layout and
-- renderer: geometry, per-code glyph quads/advances, the stacked color-band
-- metadata, the semantic glyph mask atlas path, the focus-indicator frame
-- rects, the text-to-code charmap, the 16-color palette, and source
-- provenance.

---@class FieldFontDef
---@field schema string
---@field fontId integer
---@field lineHeight integer
---@field maxLetterHeight integer
---@field letterSpacing integer
---@field glyphCount integer
---@field fallbackCode integer
---@field atlasPath string
---@field maskAtlasPath string
---@field atlas { width: integer, height: integer, baseHeight: integer, glyphsPerRow: integer, glyphWidth: integer, glyphHeight: integer }
---@field colorVariants { count: integer, strideY: integer }
---@field focusIndicators { imagePath: string, count: integer, width: integer, height: integer, frames: table<integer, { x: integer, y: integer, width: integer, height: integer }> }
---@field glyphs table<integer, { x: integer, y: integer, w: integer, h: integer, advance: integer, bearingX: integer, bearingY: integer }>
---@field charmap table<string, integer>
---@field palette { r: integer, g: integer, b: integer }[]
---@field source table

return FieldFontCompiler
