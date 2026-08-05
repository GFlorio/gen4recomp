-- Builds a synthetic NNSG3dResTex (TEX0) block holding any number of named
-- 8x8 palette16 textures and named 4-colour palettes, so tests can construct
-- texture packs that contain -- or deliberately omit -- a given name. Every
-- texture shares the same texel pattern (all index 1) and every palette the
-- same colours, which keeps the fixture small while still exercising the real
-- dictionary/offset layout the Nsbtx decoder consumes. Test-only.

local NB = require("tests.support.NitroBuilder")
local TF = require("tests.support.TextureFixtures")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")

local Tex0Fixture = {}

local TEXEL_BYTES = 32  -- 8x8 at 4bpp
local PALETTE_BYTES = 8 -- four rgb555 entries
local FORMAT_PALETTE16 = 3

-- opts: { textures = { name, ... }, palettes = { name, ... } }.
-- Returns the complete TEX0 block (magic + size + header + dicts + data).
function Tex0Fixture.block(opts)
  local texNames = opts.textures or {}
  local palNames = opts.palettes or {}
  assert(#texNames > 0, "TEX0 fixture needs at least one texture")
  assert(#palNames > 0, "TEX0 fixture needs at least one palette")

  local texEntries, palEntries = {}, {}
  for i, name in ipairs(texNames) do
    -- texelUnits (bits 0-15) is a byte offset in 8-byte units into texData.
    local param = ((i - 1) * TEXEL_BYTES / 8) + FORMAT_PALETTE16 * 0x4000000
    texEntries[#texEntries + 1] = { name = name, data = NB.u32(param) .. "\0\0\0\0" }
  end
  for i, name in ipairs(palNames) do
    palEntries[#palEntries + 1] =
      { name = name, data = NB.u16((i - 1) * PALETTE_BYTES / 8) .. NB.u16(0) }
  end

  local texDict = NB.dict(texEntries)
  local pltDict = NB.dict(palEntries)
  local ofsTexDict = 0x3C
  local ofsPlttDict = ofsTexDict + #texDict
  local ofsTexData = ofsPlttDict + #pltDict
  local texData = string.rep(string.char(0x11), TEXEL_BYTES * #texNames)
  local ofsPlttData = ofsTexData + #texData
  local palData = string.rep(TF.palette({ TF.BLACK, TF.RED, TF.BLACK, TF.BLACK }), #palNames)

  local header = "TEX0" .. NB.u32(0)
    .. NB.u32(0) .. NB.u16(#texData / 8) .. NB.u16(ofsTexDict) .. NB.u16(0) .. NB.u16(0) .. NB.u32(ofsTexData)
    .. NB.u32(0) .. NB.u16(0) .. NB.u16(ofsTexDict) .. NB.u16(0) .. NB.u16(0) .. NB.u32(0) .. NB.u32(0)
    .. NB.u32(0) .. NB.u16(#palData / 8) .. NB.u16(0) .. NB.u16(ofsPlttDict) .. NB.u16(0) .. NB.u32(ofsPlttData)
  assert(#header == 0x3C, "TEX0 header must be 0x3C, got " .. #header)

  local block = header .. texDict .. pltDict .. texData .. palData
  return block:sub(1, 4) .. NB.u32(#block) .. block:sub(9)
end

-- The same TEX0 wrapped in a BTX0 container, as a texture-archive member is
-- stored in the ROM.
function Tex0Fixture.btx0(opts)
  -- NitroBuilder.file re-emits the 8-byte block header the block already has.
  return NB.file("BTX0", { { magic = "TEX0", body = Tex0Fixture.block(opts):sub(9) } })
end

-- The bare fixture already decoded, ready to hand to MaterialCompiler.
function Tex0Fixture.pack(opts)
  return assert(Nsbtx.decodeTex0(Tex0Fixture.block(opts)))
end

return Tex0Fixture
