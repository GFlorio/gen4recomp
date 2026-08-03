-- Nsbtx.decoderOpts bridge: a synthetic TEX0 with a real 16-color texture whose
-- texels all index palette entry 1 (red) must bridge to TextureDecoder opts that
-- decode back to red pixels of the right dimensions.

local Assert = require("tests.support.Assert")
local Nsbtx = require("src.data.nitro.Nsbtx")
local TextureDecoder = require("src.data.nitro.TextureDecoder")
local NB = require("tests.support.NitroBuilder")
local TF = require("tests.support.TextureFixtures")

local T = {}

-- One 8x8 palette16 texture, all texels = index 1; palette[1] = RED.
local function buildPack()
  local paramWord = 3 * 0x4000000 -- format 3 (palette16), size 8x8, texelUnits 0
  local texDict = NB.dict({ { name = "t", data = NB.u32(paramWord) .. "\0\0\0\0" } })
  local pltDict = NB.dict({ { name = "p", data = NB.u16(0) .. NB.u16(0) } })

  local ofsTexDict = 0x3C
  local ofsPlttDict = ofsTexDict + #texDict
  local ofsTexData = ofsPlttDict + #pltDict
  local texData = string.rep(string.char(0x11), 32) -- 8x8 / 2 = 32 bytes, every nibble = 1
  local ofsPlttData = ofsTexData + #texData
  local palData = TF.palette({ TF.BLACK, TF.RED, TF.BLACK, TF.BLACK }) -- 8 bytes

  local header = "TEX0" .. NB.u32(0)
    .. NB.u32(0) .. NB.u16(#texData / 8) .. NB.u16(ofsTexDict) .. NB.u16(0) .. NB.u16(0) .. NB.u32(ofsTexData)
    .. NB.u32(0) .. NB.u16(0) .. NB.u16(ofsTexDict) .. NB.u16(0) .. NB.u16(0) .. NB.u32(0) .. NB.u32(0)
    .. NB.u32(0) .. NB.u16(#palData / 8) .. NB.u16(0) .. NB.u16(ofsPlttDict) .. NB.u16(0) .. NB.u32(ofsPlttData)
  assert(#header == 0x3C, "TEX0 header must be 0x3C, got " .. #header)

  local block = header .. texDict .. pltDict .. texData .. palData
  block = block:sub(1, 4) .. NB.u32(#block) .. block:sub(9)
  return assert(Nsbtx.decodeTex0(block))
end

function T.bridges_texture_and_palette_to_decodable_opts()
  local pack = buildPack()
  local tex = pack.textureByName["t"]
  local pal = pack.paletteByName["p"]
  local opts = Nsbtx.decoderOpts(pack, tex, pal)
  Assert.equal(#opts.texel, 32)
  Assert.equal(opts.format, 3)

  local img = TextureDecoder.decode(opts)
  Assert.equal(img.width, 8)
  Assert.equal(img.height, 8)
  Assert.equal(#img.pixels, 8 * 8 * 4)
  -- Top-left pixel indexes palette entry 1 = red, fully opaque.
  Assert.equal(string.byte(img.pixels, 1), 255) -- r
  Assert.equal(string.byte(img.pixels, 2), 0)   -- g
  Assert.equal(string.byte(img.pixels, 3), 0)   -- b
  Assert.equal(string.byte(img.pixels, 4), 255) -- a
end

function T.direct_color_needs_no_palette()
  local pack = buildPack()
  local tex = pack.textureByName["t"]
  local opts = Nsbtx.decoderOpts(pack, tex, nil)
  Assert.equal(opts.palette, "")
end

return T
