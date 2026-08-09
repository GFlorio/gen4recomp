-- Synthetic font-member and RLCN-palette decode tests (spec sections 7.7 and
-- 21.1). The fixtures are hand-authored byte strings, not ROM data.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local BinaryWriter = require("libs.rom.src.BinaryWriter")
local FieldFontDecoder = require("romdump.src.digest.FieldFontDecoder")

local T = {}

local function returnsCode(code, fn)
  local result, err = fn()
  Assert.isNil(result, "expected a failure result")
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local function buildFontMember(numGlyphs, glyphBytes, widths, opts)
  opts = opts or {}
  local gw = opts.glyphWidth or 2
  local gh = opts.glyphHeight or 2
  local glyphSize = 16 * gw * gh
  local headerSize = opts.headerSize or 16
  local widthDataStart = headerSize + #glyphBytes
  local writer = BinaryWriter.new()
  writer:u32(headerSize)
  writer:u32(widthDataStart)
  writer:u32(numGlyphs)
  writer:u8(opts.fixedWidth or 16)
  writer:u8(opts.fixedHeight or 16)
  writer:u8(gw)
  writer:u8(gh)
  writer:bytes(glyphBytes)
  for i = 1, numGlyphs do
    writer:u8(widths[i] or 6)
  end
  return writer:tostring()
end

-- One 16x16 glyph: four 8x8 sub-tiles (TL, TR, BL, BR), each 16 bytes where a
-- row is (rightByte, leftByte) and pixel 0 of a byte is its high two bits.
local function glyph64(tile)
  local tiles = {}
  for _ = 1, 4 do
    tiles[#tiles + 1] = tile or string.rep("\0", 16)
  end
  return table.concat(tiles)
end

-- bytePairs entries are { rightByte, leftByte } (first byte = right half).
local function row16(bytePairs)
  local out = {}
  for _, pair in ipairs(bytePairs) do
    out[#out + 1] = string.char(pair[1], pair[2])
  end
  return table.concat(out)
end

local function buildPalette(colors, opts)
  opts = opts or {}
  local paletteBytes = #colors * 2
  local chunkSize = 0x18 + paletteBytes
  local ttlp = "TTLP"
    .. string.char(
      chunkSize % 256,
      math.floor(chunkSize / 256) % 256,
      math.floor(chunkSize / 65536) % 256,
      math.floor(chunkSize / 16777216) % 256
    )
    .. string.char(3, 0, 0, 0, 0, 0, 0, 0)
    .. string.char(
      paletteBytes % 256,
      math.floor(paletteBytes / 256) % 256,
      math.floor(paletteBytes / 65536) % 256,
      math.floor(paletteBytes / 16777216) % 256
    )
    .. string.char(0x10, 0, 0, 0)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = string.char(c % 256, math.floor(c / 256))
  end
  local total = 0x10 + #ttlp + #table.concat(body)
  local header = "RLCN"
    .. string.char(0xFF, 0xFE, 0x00, 0x01)
    .. string.char(
      total % 256,
      math.floor(total / 256) % 256,
      math.floor(total / 65536) % 256,
      math.floor(total / 16777216) % 256
    )
    .. string.char(0x10, 0, 1, 0)
  return header .. ttlp .. table.concat(body)
end

function T.decodes_font_member_header_and_widths()
  local member = buildFontMember(
    8,
    glyph64() .. glyph64() .. glyph64() .. glyph64() .. glyph64() .. glyph64() .. glyph64() .. glyph64(),
    { 6, 7, 5 }
  )
  local font = assert(FieldFontDecoder.decodeMember(member, {}))
  Assert.equal(font.numGlyphs, 8)
  Assert.equal(font.fixedWidth, 16)
  Assert.equal(font.fixedHeight, 16)
  Assert.equal(font.glyphSize, 64)
  Assert.equal(font.glyphWidth(0), 6)
  Assert.equal(font.glyphWidth(1), 7)
  Assert.equal(font.glyphWidth(2), 5)
end

function T.glyph_tile_semantics_match_decompress_glyph_tile()
  -- Row byte pair (0x00, 0x55): left half = value 1 pixels, right = 0.
  -- Pair (0xAA, 0x00): left = 0, right = value 2. Second byte holds the left
  -- half and pixel 0 of a byte is its high two bits (DecompressGlyphTile:
  -- the half-row lookup table puts the source byte's bits 6-7 into the
  -- dest's low nibble, which is pixel 0 of a 4bpp group).
  local tl = row16({
    { 0x00, 0x55 },
    { 0x00, 0x55 },
    { 0xAA, 0x00 },
    { 0xAA, 0x00 },
    { 0x00, 0x55 },
    { 0x00, 0x55 },
    { 0xAA, 0x00 },
    { 0xAA, 0x00 },
  })
  local member = buildFontMember(1, glyph64(tl), { 6 })
  local font = assert(FieldFontDecoder.decodeMember(member, {}))
  local glyph = font.glyphPixels(0)
  Assert.equal(glyph.width, 16)
  Assert.equal(glyph.height, 16)
  Assert.equal(glyph.values[1][1], 1)
  Assert.equal(glyph.values[1][4], 1)
  Assert.equal(glyph.values[1][5], 0)
  Assert.equal(glyph.values[1][8], 0)
  Assert.equal(glyph.values[3][1], 0)
  Assert.equal(glyph.values[3][4], 0)
  Assert.equal(glyph.values[3][5], 2)
  Assert.equal(glyph.values[3][8], 2)
end

function T.glyph_code_resolution_and_fallback()
  -- A font large enough that the fallback width index (427) is in range,
  -- like the real English font (509 glyphs).
  local member = buildFontMember(430, string.rep(glyph64(), 430), { 6 })
  local font = assert(FieldFontDecoder.decodeMember(member, {}))
  Assert.equal(font.glyphIndexForCode(1), 0)
  Assert.equal(font.glyphIndexForCode(430), 429)
  -- Code 0 and codes above numGlyphs resolve to the fallback glyph index.
  Assert.equal(font.glyphIndexForCode(0), FieldFontDecoder.FALLBACK_GLYPH_INDEX)
  Assert.equal(font.glyphIndexForCode(431), FieldFontDecoder.FALLBACK_GLYPH_INDEX)
  Assert.equal(font.glyphWidth(FieldFontDecoder.FALLBACK_GLYPH_INDEX), 6)
end

function T.member_validation_is_typed()
  returnsCode("FONT_FORMAT_INVALID", function()
    return FieldFontDecoder.decodeMember("short", {})
  end)
  returnsCode("FONT_FORMAT_INVALID", function()
    local member = buildFontMember(0, "", {})
    return FieldFontDecoder.decodeMember(member, {})
  end)
  returnsCode("FONT_FORMAT_INVALID", function()
    local member = buildFontMember(2, glyph64(), {}, { glyphWidth = 3 })
    return FieldFontDecoder.decodeMember(member, {})
  end)
  returnsCode("FONT_FORMAT_INVALID", function()
    -- Glyphs would extend past the width table start.
    local member = buildFontMember(4, glyph64(), { 6 })
    return FieldFontDecoder.decodeMember(member, {})
  end)
  local member = buildFontMember(2, glyph64() .. glyph64(), { 6 })
  local font, decodeErr = FieldFontDecoder.decodeMember(member, {})
  Assert.isNil(decodeErr, "fixture must be a valid member")
  local glyphErr = Assert.throws(function()
    return assert(font).glyphPixels(5)
  end)
  Assert.isTrue(Errors.is(glyphErr))
  Assert.equal(glyphErr.code, "FONT_GLYPH_MISSING")
end

function T.decodes_rlcn_palette_and_expands_5bit_colors()
  local colors = { 0x0000, 0x296B, 0x5EF5, 0x7FFF }
  local member = buildPalette(colors)
  local palette = assert(FieldFontDecoder.decodePalette(member, {}))
  Assert.equal(palette.colorCount, 4)
  Assert.deepEqual(palette.colors[1], { r = 0, g = 0, b = 0 })
  Assert.deepEqual(palette.colors[4], { r = 255, g = 255, b = 255 })
  -- 0x296B = B11 G11 R10 -> ~(82, 90, 90)
  Assert.deepEqual(palette.colors[2], { r = 82, g = 90, b = 90 })
end

function T.palette_validation_is_typed()
  returnsCode("FONT_FORMAT_INVALID", function()
    return FieldFontDecoder.decodePalette("not a palette", {})
  end)
  returnsCode("FONT_FORMAT_INVALID", function()
    local member = buildPalette({ 0x0000 })
    local bad = member:sub(1, 4) .. string.rep("\0", #member - 4)
    return FieldFontDecoder.decodePalette(bad, {})
  end)
  returnsCode("FONT_FORMAT_INVALID", function()
    -- TTLP chunk size shorter than the palette data it declares.
    local member = buildPalette({ 0x0000, 0x0000, 0x0000, 0x0000, 0x0000 })
    return FieldFontDecoder.decodePalette(member:sub(1, #member - 2), {})
  end)
end

return T
