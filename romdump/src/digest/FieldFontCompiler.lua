-- Compiles the HGSS field font (font 0) into a private atlas PNG plus the
-- g4-field-font-v1 definition. Glyph tiles and the width table come from
-- NARC_graphic_font member 0 (src/font_data.c); colors come from the
-- RLCN-wrapped TTLP palette member 7 (src/font.c LoadFontPal0). Pixel values
-- map to palette slots via GenerateFontHalfRowLookupTable (src/text.c):
-- 0 = transparent, 1 = foreground, 2 = shadow, 3 = background.

local Errors = require("libs.rom.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldFontDecoder = require("romdump.src.digest.FieldFontDecoder")
local FieldMessageCompiler = require("romdump.src.digest.FieldMessageCompiler")
local charmap = require("data.reference.hgss.charmap")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local manifest = require("data.manifests.field_messages")

local FieldFontCompiler = {}

FieldFontCompiler.COMPILER_VERSION = "field-font-compiler-v4"
FieldFontCompiler.DECODER_VERSION = "hgss-field-font-decoder-v2"

local GLYPH_SIZE = 16

local function must(value, err)
  if value == nil then error(err) end
  return value
end

local function loadSource(romFs, sha1hex)
  local archiveInfo = romFs:resolvedNarc("font")
  if not archiveInfo then
    Errors.raise("ROMFS_NARC_UNRESOLVED", "font NARC is unavailable",
      { name = "font" })
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc("font"))
  return {
    archive = archive,
    archiveInfo = archiveInfo,
    archiveSha1 = sha1hex(archiveBytes),
  }
end

-- Composite-atlas pixel mapping: 0 = transparent, 1 = foreground ink,
-- 2 = shadow, 3 = the font's background slot. The slot numbers come from
-- sFontInfos[0] in src/font.c (fgColor = 0x01, shadowColor = 0x02,
-- bgColor = 0x0F) applied through GenerateFontHalfRowLookupTable
-- (src/text.c); palette.colors is 1-based (colors[i] = slot i-1), so the
-- index is slot + 1. The DS drew the background slot in the window fill color
-- so it *looked* transparent; in a composited atlas it must be actually
-- transparent (spec section 7.7 "transparent glyph background"), otherwise
-- every 16x16 glyph cell becomes an opaque rectangle that chops the narrower
-- glyphs placed before it.

---@param value integer
---@param palette FieldFontDecoder.Palette
---@return integer, integer, integer, integer
local function pixelToRgba(value, palette)
  if value == 0 or value == 3 then
    return 0, 0, 0, 0
  end
  local index = value == 1 and FieldFontDecoder.FG_PALETTE_INDEX + 1
    or FieldFontDecoder.SHADOW_PALETTE_INDEX + 1
  local color = palette[index] or { r = 0, g = 0, b = 0 }
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
  local paletteMember = must(source.archive:readMember(manifest.fontPaletteMember))
  local glyphSha1 = sha1hex(glyphMember)
  local paletteSha1 = sha1hex(paletteMember)

  local font = must(FieldFontDecoder.decodeMember(glyphMember, {
    label = "field-font-glyphs",
  }))
  local palette = must(FieldFontDecoder.decodePalette(paletteMember, {
    label = "field-font-palette",
  }))
  if palette.colorCount < 16 then
    Errors.raise("FONT_FORMAT_INVALID",
      "font palette has " .. palette.colorCount .. " colors, need at least 16",
      { colorCount = palette.colorCount })
  end

  local perRow = manifest.atlasGlyphsPerRow
  local rows = math.ceil(font.numGlyphs / perRow)
  local width = perRow * GLYPH_SIZE
  local height = rows * GLYPH_SIZE

  local rgba = {}
  for i = 1, width * height * 4 do rgba[i] = 0 end
  for glyphIndex = 0, font.numGlyphs - 1 do
    local glyph = font.glyphPixels(glyphIndex)
    local baseX = (glyphIndex % perRow) * GLYPH_SIZE
    local baseY = math.floor(glyphIndex / perRow) * GLYPH_SIZE
    for y = 0, 15 do
      for x = 0, 15 do
        local r, g, b, a = pixelToRgba(glyph.values[y + 1][x + 1], palette.colors)
        local offset = ((baseY + y) * width + baseX + x) * 4
        rgba[offset + 1] = r
        rgba[offset + 2] = g
        rgba[offset + 3] = b
        rgba[offset + 4] = a
      end
    end
  end
  local function concatRgba(chars)
    -- string.char/unpack are limited by the Lua stack; build in row chunks.
    local out = {}
    for i = 1, #chars, 4096 do
      out[#out + 1] = string.char(unpack(chars, i, math.min(i + 4095, #chars)))
    end
    return table.concat(out)
  end
  local atlasBytes = PngWriter.encode(width, height, concatRgba(rgba))

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
      if byte < 0x80 or byte >= 0xC0 then sequences = sequences + 1 end
    end
    return sequences == 1
  end
  local textToCode = {}
  for code, text in pairs(charmap.glyphs) do
    if isSingleCharacter(text) then
      assert(textToCode[text] == nil,
        "charmap maps multiple codes to the single character " .. text)
      textToCode[text] = code
    end
  end

  local fontDef = {
    schema = FieldFontCache.SCHEMA,
    fontId = fontId,
    atlasPath = FieldFontCache.atlasPath(fontId),
    lineHeight = font.fixedHeight,
    maxLetterHeight = font.fixedHeight,
    letterSpacing = 0,
    glyphCount = font.numGlyphs,
    fallbackCode = 0,
    atlas = {
      width = width,
      height = height,
      glyphsPerRow = perRow,
      glyphWidth = GLYPH_SIZE,
      glyphHeight = GLYPH_SIZE,
    },
    glyphs = glyphs,
    charmap = textToCode,
    palette = palette.colors,
    source = {
      narc = source.archiveInfo.symbol,
      glyphMemberId = manifest.fontGlyphMember,
      glyphMemberSha1 = glyphSha1,
      paletteMemberId = manifest.fontPaletteMember,
      paletteMemberSha1 = paletteSha1,
    },
  }

  local dependencies = {
    cacheFormat = FieldFontCache.FORMAT,
    compilerVersion = FieldFontCompiler.COMPILER_VERSION,
    decoderVersion = FieldFontCompiler.DECODER_VERSION,
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
    paletteMemberId = manifest.fontPaletteMember,
    paletteMemberSha1 = paletteSha1,
  }

  local marker = FieldFontCache.marker(romFs:metadata().sha1, hashLua(dependencies))
  return {
    fontId = fontId,
    marker = marker,
    font = fontDef,
    atlas = atlasBytes,
    dependencies = dependencies,
  }
end

---@param romFs RomFs
---@param sha1hex fun(bytes: string): string?
---@param hashLua fun(value: any): string?
---@return FieldFontCompiler.Bundle
local function _compile(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc,
    "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  return compileFont(romFs, loadSource(romFs, sha1hex), sha1hex, hashLua)
end

---@param romFs RomFs
---@param sha1hex fun(bytes: string): string?
---@param hashLua fun(value: any): string?
---@return FieldFontCompiler.Bundle?
---@return Errors.Error?
function FieldFontCompiler.compile(romFs, sha1hex, hashLua)
  local ok, result = pcall(_compile, romFs, sha1hex, hashLua)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

-- The compiled font class: the g4-field-font-v1 definition, the atlas PNG,
-- and the cache marker derived from every source dependency.

---@class FieldFontCompiler.Bundle
---@field fontId integer
---@field marker string
---@field font FieldFontDef
---@field atlas string
---@field dependencies table

-- The g4-field-font-v1 runtime definition consumed by the dialogue layout and
-- renderer: geometry, per-code glyph quads/advances, the text-to-code charmap,
-- the 16-color palette, and source provenance.

---@class FieldFontDef
---@field schema string
---@field fontId integer
---@field lineHeight integer
---@field maxLetterHeight integer
---@field letterSpacing integer
---@field glyphCount integer
---@field fallbackCode integer
---@field atlas { width: integer, height: integer, glyphsPerRow: integer, glyphWidth: integer, glyphHeight: integer }
---@field glyphs table<integer, { x: integer, y: integer, w: integer, h: integer, advance: integer, bearingX: integer, bearingY: integer }>
---@field charmap table<string, integer>
---@field palette { r: integer, g: integer, b: integer }[]
---@field source table

return FieldFontCompiler
