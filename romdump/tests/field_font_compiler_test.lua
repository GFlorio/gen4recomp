-- Deterministic field-font compilation and cache readiness/rollback using a
-- synthetic font member and RLCN palette.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldFontCompiler = require("romdump.src.digest.FieldFontCompiler")
local FieldFontDecoder = require("romdump.src.digest.FieldFontDecoder")
local FieldFontCacheWriter = require("romdump.src.digest.FieldFontCacheWriter")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local PngReader = require("tests.support.PngReader")

local T = {}

local function buildFontMember(numGlyphs, glyphBytes, widths)
  local glyphSize = 64
  local writer = require("libs.codec.src.BinaryWriter").new()
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

-- Builds a 4bpp NCGR char container over `tiles` (32 bytes per tile). The
-- layout follows GBATEK and is the shape decodeChar accepts: a 16-byte header,
-- then one CHAR block whose body carries the depth at +4, the tile byte count
-- at +0x10, the tile offset at +0x14, then the tiles.
local function buildFocusMember(tiles)
  local function u32le(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
  end
  local chunkSize = 0x18 + #tiles
  local blockSize = 8 + chunkSize
  local fileSize = 0x10 + blockSize
  local charChunk = string.char(0x00, 0x00, 0x00, 0x00)
    .. u32le(3)
    .. string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
    .. u32le(#tiles)
    .. u32le(0x18)
    .. tiles
  local block = "RAHC" .. u32le(blockSize) .. charChunk
  return "RGCN"
    .. string.char(0xFF, 0xFE)
    .. string.char(0x01, 0x01)
    .. u32le(fileSize)
    .. string.char(0x10, 0x00)
    .. string.char(0x01, 0x00)
    .. block
end

-- Encodes one 24x32 frame as its 12 row-major 8x8 4bpp tiles. `pattern` maps
-- a zero-based pixel coordinate to a 0..15 palette index. 4bpp tile bytes
-- hold two pixels with the left (even) pixel in the low nibble (GBATEK).
local function frameTiles(pattern)
  local tiles = {}
  for tileY = 0, 3 do
    for tileX = 0, 2 do
      local bytes = {}
      for row = 0, 7 do
        for pair = 0, 3 do
          local x0 = tileX * 8 + pair * 2
          local y0 = tileY * 8 + row
          bytes[#bytes + 1] = string.char(pattern(x0 + 1, y0) * 16 + pattern(x0, y0))
        end
      end
      tiles[#tiles + 1] = table.concat(bytes)
    end
  end
  return table.concat(tiles)
end

-- A bordered 24x32 rectangle of `fill` with an empty 8x8 hole in the middle, so
-- tests can probe both a visible indicator index and the transparent
-- background index in one frame.
local function indicatorsFrame(fill, border)
  return frameTiles(function(x, y)
    if x == 0 or x == 23 or y == 0 or y == 31 then
      return border
    end
    if x >= 8 and x <= 15 and y >= 12 and y <= 19 then
      return 0
    end
    return fill
  end)
end

-- Two distinct 4-frame focus members so a member-6 dependency test can swap
-- only those bytes. Each carries the 24x32 4bpp protocol shape (48 tiles).
local function focusMembers()
  local a = table.concat({
    indicatorsFrame(0x0B, 0x0D),
    indicatorsFrame(0x0C, 0x0D),
    indicatorsFrame(0x0B, 0x0D),
    indicatorsFrame(0x0C, 0x0D),
  })
  local b = table.concat({
    indicatorsFrame(0x0D, 0x0B),
    indicatorsFrame(0x0B, 0x0D),
    indicatorsFrame(0x0C, 0x0D),
    indicatorsFrame(0x0D, 0x0B),
  })
  return buildFocusMember(a), buildFocusMember(b)
end

local function fixture(opts)
  opts = opts or {}
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
  -- Slots 3..10 are the additional color-band foreground/shadow pairs and
  -- slots 11..14 the focus-indicator colors; all are distinct so the
  -- color-band and indicator mapping tests cannot pass with a degenerate
  -- palette. palette.colors is 1-based, so the compiler resolves slot N at
  -- colors[N+1].
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
    0x001F,
    0x03E0,
    0x7C00,
    0x4A94,
    0x7FFF,
  })
  local focusA, focusB = focusMembers()
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
          if memberId == 6 then
            return opts.focusMember or focusA
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
    if bytes == focusA then
      return "focus-member-a-sha"
    end
    if bytes == focusB then
      return "focus-member-b-sha"
    end
    return "archive-sha"
  end
  return romFs, sha1, function()
    return "dependency-sha"
  end, { focusA = focusA, focusB = focusB }
end

function T.compiles_font_def_and_atlas()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  Assert.equal(bundle.font.schema, FieldFontCache.SCHEMA)
  Assert.equal(bundle.font.fontId, 0)
  Assert.equal(bundle.font.lineHeight, 16)
  Assert.equal(bundle.font.maxLetterHeight, 16)
  Assert.equal(bundle.font.letterSpacing, 0)
  Assert.equal(bundle.font.glyphCount, 1)
  Assert.equal(bundle.font.atlas.width, 1024)
  Assert.equal(bundle.font.atlas.height, 16 * 7)
  Assert.equal(bundle.font.atlas.baseHeight, 16)
  Assert.equal(bundle.font.glyphs[1].advance, 6)
  Assert.equal(bundle.font.charmap["A"], 0x12B)
  Assert.equal(bundle.font.charmap[" "], 0x01DE)
  Assert.equal(bundle.font.glyphs[1].w, 16)
  -- Fallback resolves to glyph index 427 (its atlas cell in the grid).
  Assert.equal(bundle.font.glyphs[0].x, 688)
  Assert.equal(bundle.font.glyphs[0].y, 96)
  Assert.isNil(bundle.font.source, "font source identity lives in the dependency record")
  Assert.equal(bundle.dependencies.glyphMemberSha1, "glyph-member-sha")
  Assert.equal(bundle.dependencies.paletteMemberSha1, "palette-member-sha")
  Assert.equal(bundle.dependencies.glyphMemberId, 0)
  Assert.equal(bundle.dependencies.paletteMemberId, 7)
  Assert.equal(bundle.marker, "field-font-cache-v2:rom-sha:dependency-sha")

  -- The 8x8 sub-tile is repeated for all four quadrants: each row is
  -- (right=0xAA shadow, left=0x55 fg), so every quadrant's left half is
  -- fg (slot 1, 0x296B -> 82,90,90) and its right half is shadow
  -- (slot 2, 0x5EF5 -> 189,189,173), resolved at colors[slot+1].
  local atlasWidth, _, rgba = PngReader.rgba(bundle.atlas)
  Assert.equal(atlasWidth, 1024)
  local r, g, b, a = PngReader.pixel(rgba, atlasWidth, 0, 0)
  Assert.equal(a, 255)
  Assert.equal(r, 82)
  Assert.equal(g, 90)
  Assert.equal(b, 90)
  local r2, g2, b2, a2 = PngReader.pixel(rgba, atlasWidth, 4, 0)
  Assert.equal(a2, 255)
  Assert.equal(r2, 189)
  Assert.equal(g2, 189)
  Assert.equal(b2, 173)
  local r3, g3, b3, a3 = PngReader.pixel(rgba, atlasWidth, 0, 8)
  Assert.equal(a3, 255) -- BL tile repeats the same pattern
  Assert.equal(r3, 82)
  local r4, g4, b4, a4 = PngReader.pixel(rgba, atlasWidth, 12, 8)
  Assert.equal(a4, 255)
  Assert.equal(r4, 189) -- BR right half carries the shadow too
  -- Background-slot pixels (value 3) composite as transparent so glyph cells
  -- never paint opaque rectangles over the narrower glyphs before them.
  local r5, g5, b5, a5 = PngReader.pixel(rgba, atlasWidth, 5, 0)
  Assert.equal(a5, 0)
  Assert.equal(r5, 0)
  local r6, g6, b6, a6 = PngReader.pixel(rgba, atlasWidth, 7, 0)
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
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
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
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
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

-- The font derived class imports font member 6 and reports four 24x32 focus
-- frames with explicit in-bounds rects plus the dependency record.
function T.font_def_exposes_four_24x32_focus_frames_and_member6_dependencies()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local focus = bundle.font.focusIndicators
  Assert.notNil(focus, "the font definition must expose the focus indicator asset")
  Assert.equal(focus.imagePath, "assets/generated/field/font/font-0-focus-indicators.png")
  Assert.equal(focus.count, 4)
  Assert.equal(focus.width, 24)
  Assert.equal(focus.height, 32)
  local focusW, focusH, _ = PngReader.rgba(bundle.focusIndicators)
  for field = 0, focus.count - 1 do
    local rect = focus.frames[field]
    Assert.notNil(rect, "focus frame " .. field .. " must have a rect")
    Assert.equal(rect.width, 24, "focus frame " .. field .. " must be 24 wide")
    Assert.equal(rect.height, 32, "focus frame " .. field .. " must be 32 tall")
    Assert.isTrue(rect.x >= 0 and rect.y >= 0, "focus frame rects are non-negative")
    Assert.isTrue(
      rect.x + rect.width <= focusW and rect.y + rect.height <= focusH,
      "focus frame " .. field .. " must lie inside the focus PNG"
    )
  end
  Assert.equal(bundle.dependencies.focusIndicatorMemberId, 6)
  Assert.equal(bundle.dependencies.focusIndicatorMemberSha1, "focus-member-a-sha")
end

-- A malformed focus member (invalid container or truncated payload) fails
-- the whole font compile with a typed format error; the compiler never emits
-- fewer frames.
function T.malformed_focus_members_fail_with_a_typed_format_error()
  for _, bad in ipairs({ "not-an-ncgr", "RGCN" .. string.rep("\0", 12) }) do
    local romFs, sha1, hashLua = fixture({ focusMember = bad })
    local bundle, err = FieldFontCompiler.compile(romFs, sha1, hashLua)
    Assert.isNil(bundle, "a malformed focus member must fail the font compile")
    Assert.isTrue(Errors.is(err), "the focus failure must be a typed format error")
  end
end

-- The compiled definition reports seven color bands that share the base
-- atlas geometry via a positive stride, and the atlas is tall enough for every
-- band.
function T.the_font_def_reports_seven_color_bands_over_the_base_geometry()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local variants = bundle.font.colorVariants
  Assert.notNil(variants, "the font definition must expose colorVariants")
  Assert.equal(variants.count, 7)
  Assert.isTrue(
    variants.strideY > 0 and variants.strideY == math.floor(variants.strideY),
    "strideY must be a positive integer"
  )
  Assert.equal(bundle.font.atlas.height / variants.count, bundle.font.atlas.baseHeight)
  local _, atlasH, _ = PngReader.rgba(bundle.atlas)
  Assert.equal(atlasH, bundle.font.atlas.height)
  for variant = 1, variants.count - 1 do
    Assert.isTrue(
      bundle.font.glyphs[1].y + variant * variants.strideY + bundle.font.glyphs[1].h <= bundle.font.atlas.height,
      "variant " .. variant .. " band must fit inside the atlas"
    )
  end
end

-- Each color variant resolves the source 1/2 pixel pair to palette slots
-- 2n+1 (foreground) and 2n+2 (shadow), verified against the imported palette.
function T.color_variants_resolve_the_foreground_and_shadow_palette_pairs()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local variants = bundle.font.colorVariants
  Assert.notNil(variants, "the font definition must expose colorVariants")
  local atlasW, _, rgba = PngReader.rgba(bundle.atlas)
  for variant = 0, 6 do
    local fgSlot = variant * 2 + 1
    local shadowSlot = variant * 2 + 2
    local fg = bundle.font.palette[fgSlot + 1]
    local shadow = bundle.font.palette[shadowSlot + 1]
    local r, g, b, a = PngReader.pixel(rgba, atlasW, 0, variant * variants.strideY)
    Assert.equal(a, 255, "variant " .. variant .. " foreground pixel must be opaque")
    Assert.deepEqual({ r = r, g = g, b = b }, fg, "variant " .. variant .. " foreground uses slot " .. fgSlot)
    local r2, g2, b2, a2 = PngReader.pixel(rgba, atlasW, 4, variant * variants.strideY)
    Assert.equal(a2, 255, "variant " .. variant .. " shadow pixel must be opaque")
    Assert.deepEqual({ r = r2, g = g2, b = b2 }, shadow, "variant " .. variant .. " shadow uses slot " .. shadowSlot)
  end
end

-- The default band keeps the previous default palette slots (FG 1,
-- shadow 2), so Trainer Card and unstyled dialogue stay unchanged.
function T.variant_zero_keeps_the_previous_default_palette_slots()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local variants = bundle.font.colorVariants
  local atlasW, _, rgba = PngReader.rgba(bundle.atlas)
  local r, g, b, _ = PngReader.pixel(rgba, atlasW, 0, 0)
  Assert.deepEqual(
    { r = r, g = g, b = b },
    bundle.font.palette[FieldFontDecoder.FG_PALETTE_INDEX + 1],
    "default variant foreground stays the previous FG_PALETTE_INDEX slot"
  )
  local r2, g2, b2, _ = PngReader.pixel(rgba, atlasW, 4, 0)
  Assert.deepEqual(
    { r = r2, g = g2, b = b2 },
    bundle.font.palette[FieldFontDecoder.SHADOW_PALETTE_INDEX + 1],
    "default variant shadow stays the previous SHADOW_PALETTE_INDEX slot"
  )
end

-- The focus-indicator PNG keeps visible source palette slots while the
-- background index composites transparent.
function T.focus_indicator_png_keeps_ink_slots_and_makes_the_background_transparent()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local focus = bundle.font.focusIndicators
  Assert.notNil(focus, "the font definition must expose focusIndicators")
  local focusW, _, rgba = PngReader.rgba(bundle.focusIndicators)
  local rect = focus.frames[0]
  local r, g, b, a = PngReader.pixel(rgba, focusW, rect.x + 2, rect.y + 2)
  Assert.equal(a, 255, "visible indicator pixels must stay opaque")
  Assert.deepEqual(
    { r = r, g = g, b = b },
    bundle.font.palette[0x0B + 1],
    "visible indicator pixels keep their source slot"
  )
  local rb, gb, bb, ab = PngReader.pixel(rgba, focusW, rect.x + 12, rect.y + 16)
  Assert.equal(ab, 0, "the indicator background index must composite transparent")
  Assert.equal(rb, 0)
  Assert.equal(gb, 0)
  Assert.equal(bb, 0)
end

-- When only the member 6 bytes change, the font dependency marker
-- changes; hashing the member id alone would not catch a recompiled member.
function T.changing_only_member6_bytes_changes_the_font_marker()
  local hashLua = function(value)
    return LuaWriter.encode(value)
  end
  local romFs, sha1 = fixture()
  local first = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  local _, _, _, members = fixture()
  local second = assert(FieldFontCompiler.compile(fixture({ focusMember = members.focusB }), sha1, hashLua))
  Assert.isTrue(first.marker ~= second.marker, "member 6 bytes must participate in the font dependency marker")
end

-- A cache that is missing the focus-indicator PNG must not be ready, so a
-- stale pre-change font cache cannot pass readiness after the contract bump.
function T.cache_missing_the_focus_indicator_png_is_not_ready()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldFontCacheWriter.write(cache, bundle)
  cache:remove(FieldFontCache.focusIndicatorsPath(0))
  Assert.isFalse(FieldFontCache.isReady(cache, 0, bundle.marker), "a cache without the focus PNG must not be ready")
end

return { tests = T }
