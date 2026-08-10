-- Deterministic field-font compilation and cache readiness/rollback using a
-- synthetic font member and RLCN palette (spec section 21.1).

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldFontCompiler = require("romdump.src.digest.FieldFontCompiler")
local FieldFontCacheWriter = require("romdump.src.digest.FieldFontCacheWriter")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.rom.src.LuaWriter")

local T = {}

local function buildFontMember(numGlyphs, glyphBytes, widths)
  local glyphSize = 64
  local writer = require("libs.rom.src.BinaryWriter").new()
  writer:u32(16)
  writer:u32(16 + #glyphBytes)
  writer:u32(numGlyphs)
  writer:u8(16)
  writer:u8(16)
  writer:u8(2)
  writer:u8(2)
  writer:bytes(glyphBytes)
  for i = 1, numGlyphs do
    writer:u8(widths[i] or 6)
  end
  return writer:tostring()
end

local function buildPalette(colors)
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

local function glyph64(tile)
  local tiles = {}
  for _ = 1, 4 do
    tiles[#tiles + 1] = tile or string.rep("\0", 16)
  end
  return table.concat(tiles)
end

local function fixture()
  -- One glyph: value-1 pixels on the left half, value-2 on the right, so the
  -- atlas and def expose both ink colors; the first row's right half also
  -- carries value-3 (background-slot) pixels, which must composite as
  -- transparent (0xBB = pixels 2,3,2,3 with pixel 0 = high bits, matching
  -- DecompressGlyphTile).
  -- Row bytes (right, left): left half = value 1 (fg), right half = value 2.
  local tile = string.char(0xBB, 0x55) .. string.rep(string.char(0xAA, 0x55), 7)
  local glyphMember = buildFontMember(1, glyph64(tile), { 6 })
  -- Font palette slots mirroring the ROM font palette (src/font.c
  -- sFontInfos[0]: fgColor=1, shadowColor=2, bgColor=0xF): slot 0 = unused
  -- green, 1 = fg (0x296B dark), 2 = shadow (0x5EF5 gray), 15 = bg (white).
  -- palette.colors is 1-based, so the compiler resolves slot N at colors[N+1].
  local paletteMember = buildPalette({
    0x3713,
    0x296B,
    0x5EF5,
    0x089D,
    0x5EBF,
    0x0F45,
    0x47B3,
    0x7DC0,
    0x76EF,
    0x5E5F,
    0x737F,
    0,
    0,
    0,
    0,
    0x7FFF,
  })
  local romFs = {
    resolvedNarc = function(_, alias)
      Assert.equal(alias, "font")
      return { symbol = "NARC_graphic_font", alias = "font", narcId = 16, fileId = 66, path = "a/0/1/6" }
    end,
    read = function(_, fileId)
      Assert.equal(fileId, 66)
      return "archive-bytes"
    end,
    openNarc = function(_, alias)
      Assert.equal(alias, "font")
      return {
        readMember = function(_, memberId)
          if memberId == 0 then
            return glyphMember
          end
          if memberId == 7 then
            return paletteMember
          end
          Assert.fail("unexpected font member " .. tostring(memberId))
        end,
      }
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  local function sha1(bytes)
    if bytes == glyphMember then
      return "glyph-member-sha"
    end
    if bytes == paletteMember then
      return "palette-member-sha"
    end
    return "archive-sha"
  end
  return romFs, sha1, function()
    return "dependency-sha"
  end
end

-- PngWriter emits a stored-DEFLATE, filter-0 RGBA PNG; this test-side reader
-- recovers the raw RGBA rows so pixel colors can be asserted directly.
local function pngRgba(png)
  Assert.equal(png:sub(1, 8), string.char(137, 80, 78, 71, 13, 10, 26, 10))
  local width = string.byte(png, 17) * 16777216
    + string.byte(png, 18) * 65536
    + string.byte(png, 19) * 256
    + string.byte(png, 20)
  local height = string.byte(png, 21) * 16777216
    + string.byte(png, 22) * 65536
    + string.byte(png, 23) * 256
    + string.byte(png, 24)
  -- Find the IDAT payload (first chunk after IHDR).
  local idatLen = string.byte(png, 34) * 16777216
    + string.byte(png, 35) * 65536
    + string.byte(png, 36) * 256
    + string.byte(png, 37)
  local payload = png:sub(42, 41 + idatLen)
  -- Skip the zlib header (2 bytes), then consume stored DEFLATE blocks.
  local pos = 3
  local raw = {}
  repeat
    local final = string.byte(payload, pos)
    local len = string.byte(payload, pos + 1) + string.byte(payload, pos + 2) * 256
    raw[#raw + 1] = payload:sub(pos + 5, pos + 4 + len)
    pos = pos + 5 + len
  until final % 2 == 1
  local rows = table.concat(raw)
  Assert.equal(#rows, height * (width * 4 + 1))
  local rgba = {}
  for y = 0, height - 1 do
    local row = rows:sub(y * (width * 4 + 1) + 2, (y + 1) * (width * 4 + 1))
    Assert.equal(string.byte(rows, y * (width * 4 + 1) + 1), 0, "filter must be 0")
    rgba[#rgba + 1] = row
  end
  return width, height, table.concat(rgba)
end

local function px(rgba, width, x, y)
  local offset = (y * width + x) * 4 + 1
  return string.byte(rgba, offset),
    string.byte(rgba, offset + 1),
    string.byte(rgba, offset + 2),
    string.byte(rgba, offset + 3)
end

function T.compiles_font_def_and_atlas()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  Assert.equal(bundle.font.schema, FieldFontCache.SCHEMA)
  Assert.equal(bundle.font.fontId, 0)
  Assert.equal(bundle.font.lineHeight, 16)
  Assert.equal(bundle.font.maxLetterHeight, 16)
  Assert.equal(bundle.font.letterSpacing, 0)
  Assert.equal(bundle.font.glyphCount, 1)
  Assert.equal(bundle.font.atlas.width, 1024)
  Assert.equal(bundle.font.atlas.height, 16)
  Assert.equal(bundle.font.glyphs[1].advance, 6)
  Assert.equal(bundle.font.charmap["A"], 0x12B)
  Assert.equal(bundle.font.charmap[" "], 0x01DE)
  Assert.equal(bundle.font.glyphs[1].w, 16)
  -- Fallback resolves to glyph index 427 (its atlas cell in the grid).
  Assert.equal(bundle.font.glyphs[0].x, 688)
  Assert.equal(bundle.font.glyphs[0].y, 96)
  Assert.equal(bundle.font.source.glyphMemberSha1, "glyph-member-sha")
  Assert.equal(bundle.font.source.paletteMemberSha1, "palette-member-sha")
  Assert.equal(bundle.dependencies.glyphMemberId, 0)
  Assert.equal(bundle.dependencies.paletteMemberId, 7)
  Assert.equal(bundle.marker, "field-font-cache-v1:rom-sha:dependency-sha")

  -- The 8x8 sub-tile is repeated for all four quadrants: each row is
  -- (right=0xAA shadow, left=0x55 fg), so every quadrant's left half is
  -- fg (slot 1, 0x296B -> 82,90,90) and its right half is shadow
  -- (slot 2, 0x5EF5 -> 189,189,173), resolved at colors[slot+1].
  local atlasWidth, _, rgba = pngRgba(bundle.atlas)
  Assert.equal(atlasWidth, 1024)
  local r, g, b, a = px(rgba, atlasWidth, 0, 0)
  Assert.equal(a, 255)
  Assert.equal(r, 82)
  Assert.equal(g, 90)
  Assert.equal(b, 90)
  local r2, g2, b2, a2 = px(rgba, atlasWidth, 4, 0)
  Assert.equal(a2, 255)
  Assert.equal(r2, 189)
  Assert.equal(g2, 189)
  Assert.equal(b2, 173)
  local r3, g3, b3, a3 = px(rgba, atlasWidth, 0, 8)
  Assert.equal(a3, 255) -- BL tile repeats the same pattern
  Assert.equal(r3, 82)
  local r4, g4, b4, a4 = px(rgba, atlasWidth, 12, 8)
  Assert.equal(a4, 255)
  Assert.equal(r4, 189) -- BR right half carries the shadow too
  -- Background-slot pixels (value 3) composite as transparent so glyph cells
  -- never paint opaque rectangles over the narrower glyphs before them.
  local r5, g5, b5, a5 = px(rgba, atlasWidth, 5, 0)
  Assert.equal(a5, 0)
  Assert.equal(r5, 0)
  local r6, g6, b6, a6 = px(rgba, atlasWidth, 7, 0)
  Assert.equal(a6, 0)
end

function T.compilation_is_deterministic()
  local romFs, sha1, hashLua = fixture()
  local a = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  local b = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  Assert.equal(a.atlas, b.atlas)
  Assert.equal(LuaWriter.encode(a.font), LuaWriter.encode(b.font))
  Assert.equal(a.marker, b.marker)
end

function T.writer_commits_marker_last_and_reads_back()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldFontCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldFontCache.isReady(cache, 0, bundle.marker))
  Assert.isFalse(FieldFontCache.isReady(cache, 0, bundle.marker .. "-stale"))
  local def = assert(cache:loadLua(FieldFontCache.defPath(0)))
  Assert.equal(def.schema, FieldFontCache.SCHEMA)
  Assert.isTrue(cache:exists(FieldFontCache.atlasPath(0), "file"))
end

function T.writer_failure_invalidates_the_class()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local originalWrite = backend.write
  ---@diagnostic disable: duplicate-set-field
  backend.write = function(self, path, data)
    if path:find("font-0.png", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  Assert.throws(function()
    FieldFontCacheWriter.write(cache, bundle)
  end)
  Assert.isFalse(cache:exists(FieldFontCache.dir()))
end

function T.failed_rebuild_preserves_the_previous_font()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldFontCacheWriter.write(cache, first)
  local originalWrite = backend.write
  ---@diagnostic disable: duplicate-set-field
  backend.write = function(self, path, data)
    if path:find("font-0.png", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  second.marker = FieldFontCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldFontCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldFontCache.isReady(cache, 0, first.marker), "the previous font remains ready")
  Assert.equal(cache:read(FieldFontCache.markerPath()), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-font"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldFontCacheWriter.write(cache, second)
  Assert.isTrue(FieldFontCache.isReady(cache, 0, second.marker), "a retry publishes the new font")
end

function T.corrupt_palette_member_is_typed()
  local glyphMember = buildFontMember(1, glyph64(), { 6 })
  local romFs, sha1, hashLua = fixture()
  romFs.openNarc = function()
    return {
      readMember = function(_, memberId)
        if memberId == 0 then
          return glyphMember
        end
        return "not-rlcn"
      end,
    }
  end
  local bundle, err = FieldFontCompiler.compile(romFs, sha1, hashLua)
  Assert.isNil(bundle, "expected a failure result")
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "FONT_FORMAT_INVALID")
end

return T
