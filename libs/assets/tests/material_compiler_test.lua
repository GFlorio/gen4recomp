-- MaterialCompiler: textured materials get a content hash + decoded asset,
-- untextured materials get none, identical texture references deduplicate, and
-- missing texture/palette names are hard errors.

local Assert = require("tests.support.Assert")
local MaterialCompiler = require("libs.assets.src.MaterialCompiler")
local Nsbtx = require("libs.assets.src.nitro.Nsbtx")
local Errors = require("libs.rom.src.Errors")
local NB = require("tests.support.NitroBuilder")
local TF = require("tests.support.TextureFixtures")

local T = {}

-- One 8x8 palette16 texture "t" (all texels index 1) + palette "p".
local function buildPack()
  local paramWord = 3 * 0x4000000
  local texDict = NB.dict({ { name = "t", data = NB.u32(paramWord) .. "\0\0\0\0" } })
  local pltDict = NB.dict({ { name = "p", data = NB.u16(0) .. NB.u16(0) } })
  local ofsTexDict = 0x3C
  local ofsPlttDict = ofsTexDict + #texDict
  local ofsTexData = ofsPlttDict + #pltDict
  local texData = string.rep(string.char(0x11), 32)
  local ofsPlttData = ofsTexData + #texData
  local palData = TF.palette({ TF.BLACK, TF.RED, TF.BLACK, TF.BLACK })
  local header = "TEX0" .. NB.u32(0)
    .. NB.u32(0) .. NB.u16(#texData / 8) .. NB.u16(ofsTexDict) .. NB.u16(0) .. NB.u16(0) .. NB.u32(ofsTexData)
    .. NB.u32(0) .. NB.u16(0) .. NB.u16(ofsTexDict) .. NB.u16(0) .. NB.u16(0) .. NB.u32(0) .. NB.u32(0)
    .. NB.u32(0) .. NB.u16(#palData / 8) .. NB.u16(0) .. NB.u16(ofsPlttDict) .. NB.u16(0) .. NB.u32(ofsPlttData)
  local block = header .. texDict .. pltDict .. texData .. palData
  block = block:sub(1, 4) .. NB.u32(#block) .. block:sub(9)
  return assert(Nsbtx.decodeTex0(block))
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function T.textured_untextured_and_dedup()
  local out = MaterialCompiler.compile({
    { index = 0, name = "m0", textureName = "t", paletteName = "p" },
    { index = 1, name = "m1" }, -- untextured
    { index = 2, name = "m2", textureName = "t", paletteName = "p" }, -- same texture -> dedup
  }, buildPack())

  Assert.equal(#out.materials, 3)
  Assert.equal(#out.materials[1].texture, 40) -- 40 hex chars
  Assert.isNil(out.materials[2].texture)
  Assert.equal(out.materials[1].texture, out.materials[3].texture)
  Assert.equal(countKeys(out.textures), 1) -- deduplicated

  local asset = out.textures[out.materials[1].texture]
  Assert.equal(asset.width, 8)
  Assert.equal(#asset.pixels, 8 * 8 * 4)
  Assert.isTrue(asset.alphaUsage.hasOpaque)
  Assert.isFalse(asset.alphaUsage.hasZero)
  Assert.isFalse(asset.alphaUsage.hasPartial)
  Assert.equal(out.materials[1].textureFormat, 3)
  Assert.isNil(out.materials[1].alphaMode)
  Assert.isNil(out.materials[1].cullMode)
end

function T.missing_texture_raises()
  local ok, err = pcall(MaterialCompiler.compile,
    { { index = 0, name = "m", textureName = "nope" } }, buildPack())
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MAP_COMPILE_MISSING_TEXTURE", "raises")
end

function T.missing_palette_raises()
  local ok, err = pcall(MaterialCompiler.compile,
    { { index = 0, name = "m", textureName = "t" } }, buildPack()) -- paletted format, no palette
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MAP_COMPILE_MISSING_PALETTE", "raises")
end

return T
