-- Synthetic TEX0 tests. Assembles a TEX0 block matching NNSG3dResTex (header
-- fields at their real offsets plus texture/palette dicts and data blocks) and
-- checks that Nsbtx recovers texture params (format, size, flags, color0) and
-- palette offsets with exact byte ranges.

local Assert = require("tests.support.Assert")
local Nsbtx = require("libs.assets.src.nitro.Nsbtx")
local NB = require("tests.support.NitroBuilder")

local T = {}

-- Pack a GX TEXIMAGE_PARAM-style word from fields.
local function param(o)
  return (o.texelUnits or 0)
    + (o.repeatS or 0) * 0x10000 + (o.repeatT or 0) * 0x20000
    + (o.flipS or 0) * 0x40000 + (o.flipT or 0) * 0x80000
    + (o.sizeS or 0) * 0x100000 + (o.sizeT or 0) * 0x800000
    + (o.format or 0) * 0x4000000 + (o.color0 or 0) * 0x20000000
end

local function buildTex0()
  local texEntries = {
    { name = "tex_a", data = NB.u32(param({ sizeS = 1, sizeT = 1, format = 3 })) .. "\0\0\0\0" },
    { name = "tex_b", data = NB.u32(param({ texelUnits = 16, format = 2, color0 = 1 })) .. "\0\0\0\0" },
  }
  local pltEntries = {
    { name = "pal_a", data = NB.u16(0) .. NB.u16(1) },
    { name = "pal_b", data = NB.u16(2) .. NB.u16(0) },
  }
  local texDict = NB.dict(texEntries)
  local pltDict = NB.dict(pltEntries)

  local ofsTexDict = 0x3C
  local ofsPlttDict = ofsTexDict + #texDict
  local ofsTexData = ofsPlttDict + #pltDict
  local texData = string.rep("\0", 256)
  local ofsPlttData = ofsTexData + #texData
  local palData = string.rep("\0", 64)

  local sizeTex = math.floor(#texData / 8)
  local sizePltt = math.floor(#palData / 8)

  local header = "TEX0" .. NB.u32(0) -- size patched below
    .. NB.u32(0) .. NB.u16(sizeTex) .. NB.u16(ofsTexDict) .. NB.u16(0) .. NB.u16(0) .. NB.u32(ofsTexData)
    .. NB.u32(0) .. NB.u16(0) .. NB.u16(ofsTexDict) .. NB.u16(0) .. NB.u16(0) .. NB.u32(0) .. NB.u32(0)
    .. NB.u32(0) .. NB.u16(sizePltt) .. NB.u16(0) .. NB.u16(ofsPlttDict) .. NB.u16(0) .. NB.u32(ofsPlttData)
  assert(#header == 0x3C, "TEX0 header must be 0x3C, got " .. #header)

  local block = header .. texDict .. pltDict .. texData .. palData
  return block:sub(1, 4) .. NB.u32(#block) .. block:sub(9),
    { ofsTexData = ofsTexData, ofsPlttData = ofsPlttData }
end

function T.decodes_texture_records()
  local block = buildTex0()
  local tex = assert(Nsbtx.decodeTex0(block))
  Assert.equal(#tex.textures, 2)
  local a = tex.textureByName["tex_a"]
  Assert.equal(a.format, "palette16")
  Assert.equal(a.formatRaw, 3)
  Assert.equal(a.width, 16)
  Assert.equal(a.height, 16)
  Assert.isFalse(a.color0Transparent)
  Assert.equal(a.dataSize, 16 * 16 / 2)

  local b = tex.textureByName["tex_b"]
  Assert.equal(b.format, "palette4")
  Assert.equal(b.width, 8)
  Assert.equal(b.height, 8)
  Assert.isTrue(b.color0Transparent)
  Assert.equal(b.texelOffset, 16 * 8) -- 16 units * 8 bytes
end

function T.texture_data_offset_is_absolute()
  local block, ofs = buildTex0()
  local tex = assert(Nsbtx.decodeTex0(block))
  Assert.equal(tex.textureByName["tex_a"].dataAbsolute, ofs.ofsTexData + 0)
  Assert.equal(tex.textureByName["tex_b"].dataAbsolute, ofs.ofsTexData + 16 * 8)
end

function T.decodes_palette_records()
  local block, ofs = buildTex0()
  local tex = assert(Nsbtx.decodeTex0(block))
  Assert.equal(#tex.palettes, 2)
  Assert.equal(tex.paletteByName["pal_a"].dataAbsolute, ofs.ofsPlttData + 0)
  Assert.equal(tex.paletteByName["pal_b"].dataAbsolute, ofs.ofsPlttData + 16)
end

function T.rejects_non_tex0_block()
  local tex, err = Nsbtx.decodeTex0("XXXX" .. string.rep("\0", 60))
  Assert.isNil(tex)
  Assert.equal(err.code, "NSBTX_BAD_MAGIC")
end

return T
