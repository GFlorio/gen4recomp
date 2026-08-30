-- Builds a synthetic NNSG3dResTex (TEX0) block holding any number of named
-- textures and named palettes, so tests can construct texture packs that
-- contain -- or deliberately omit -- a given name, with per-texture texel
-- bytes and per-palette colours under the real dictionary/offset layout the
-- Nsbtx decoder consumes. Test-only.

-- Entries may be plain names for the defaults, or tables that override the
-- per-entry bytes and shape:
--   textures: { name | { name, texel = bytes, format = 2..7, width = 8*2^n,
--                         height = 8*2^n, plttIdx = bytes } }
--   palettes: { name | { name, palette = bytes } }
-- A texture defaults to 8x8 palette16 whose texels are `texelBytes(format,
-- width, height)` bytes of index 1; a palette defaults to the four colours
-- below. Format 5 (compressed4x4) textures live in the TEX0 4x4 block, and
-- `plttIdx` supplies that texture's u16 control-word region; the decoder
-- slices exactly `plttIdx`'s length, so a shorter region authors an
-- auxiliary/index-data length mismatch.

local NB = require("tests.support.NitroBuilder")
local TF = require("tests.support.TextureFixtures")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")

local Tex0Fixture = {}

local FORMAT_PALETTE16 = 3

-- Texel byte length for a format/dimension pair, mirroring the Nsbtx
-- decoder's texelBytes math so default texels stay decodable.
local function texelBytes(format, width, height)
  local texels = width * height
  if format == 1 or format == 4 or format == 6 then
    return texels
  end
  if format == 2 or format == 5 then
    return math.floor(texels / 4)
  end
  if format == 3 then
    return math.floor(texels / 2)
  end
  if format == 7 then
    return texels * 2
  end
  error("unsupported fixture texture format " .. tostring(format))
end

local function textureEntry(e)
  local format = e.format or FORMAT_PALETTE16
  local width = e.width or 8
  local height = e.height or 8
  assert(width % 8 == 0 and height % 8 == 0, "fixture texture dimensions are 8 * 2^n")
  local texel = e.texel or string.rep(string.char(0x11), texelBytes(format, width, height))
  assert(#texel % 8 == 0, "fixture texels are 8-byte units")
  return {
    name = e.name,
    format = format,
    width = width,
    height = height,
    texel = texel,
    plttIdx = e.plttIdx,
    sizeS = math.log(width / 8) / math.log(2),
    sizeT = math.log(height / 8) / math.log(2),
  }
end

-- opts: { textures = { name | { name, ... }, ... }, palettes = { name |
-- { name, palette } } }.
-- Returns the complete TEX0 block (magic + size + header + dicts + data).
function Tex0Fixture.block(opts)
  local texNames = opts.textures or {}
  local palNames = opts.palettes or {}
  assert(#texNames > 0, "TEX0 fixture needs at least one texture")

  -- Format 5 texels live in the TEX0 4x4 block; every other format in the
  -- texData block. The TEXIMAGE_PARAM low bits hold the 8-byte-unit offset
  -- into the owning block; sizeS/sizeT bits carry the dimensions.
  local texData, tex4x4Data, texDictEntries = {}, {}, {}
  local ofsTex, ofsTex4x4 = 0, 0
  local plttIdx = ""
  for _, e in ipairs(texNames) do
    local entry = textureEntry(type(e) == "string" and { name = e } or e)
    local block = entry.format == 5 and tex4x4Data or texData
    block[#block + 1] = entry.texel
    if entry.format == 5 and entry.plttIdx then
      -- Control words are a u16 per 4x4 block: byte offset / 2.
      while #plttIdx < math.floor(ofsTex4x4 / 2) do
        plttIdx = plttIdx .. "\0"
      end
      plttIdx = plttIdx .. entry.plttIdx
    end
    local param = (entry.format == 5 and ofsTex4x4 or ofsTex) / 8
      + entry.format * 0x4000000
      + entry.sizeS * 0x100000
      + entry.sizeT * 0x800000
    texDictEntries[#texDictEntries + 1] = { name = entry.name, data = NB.u32(param) .. "\0\0\0\0" }
    if entry.format == 5 then
      ofsTex4x4 = ofsTex4x4 + #entry.texel
    else
      ofsTex = ofsTex + #entry.texel
    end
  end

  local palDictEntries, palBytes = {}, {}
  local ofsPal = 0
  for _, p in ipairs(palNames) do
    local entry = type(p) == "string" and { name = p } or p
    local bytes = entry.palette or TF.palette({ TF.BLACK, TF.RED, TF.BLACK, TF.BLACK })
    assert(#bytes % 8 == 0, "fixture palettes are 8-byte units")
    palDictEntries[#palDictEntries + 1] = { name = entry.name, data = NB.u16(ofsPal / 8) .. NB.u16(0) }
    palBytes[#palBytes + 1] = bytes
    ofsPal = ofsPal + #bytes
  end

  local texDict = NB.dict(texDictEntries)
  local pltDict = NB.dict(palDictEntries)
  local ofsTexDict = 0x3C
  local ofsPlttDict = ofsTexDict + #texDict
  local ofsTexData = ofsPlttDict + #pltDict
  local texDataBytes = table.concat(texData)
  local tex4x4Bytes = table.concat(tex4x4Data)
  local ofsTex4x4Data = ofsTexData + #texDataBytes
  local ofsTex4x4PlttIdx = ofsTex4x4Data + #tex4x4Bytes
  local palData = table.concat(palBytes)
  local ofsPlttData = ofsTex4x4PlttIdx + #plttIdx

  local header = "TEX0"
    .. NB.u32(0)
    .. NB.u32(0)
    .. NB.u16(math.floor(#texDataBytes / 8))
    .. NB.u16(ofsTexDict)
    .. NB.u16(0)
    .. NB.u16(0)
    .. NB.u32(ofsTexData)
    .. NB.u32(0)
    .. NB.u16(math.floor(#tex4x4Bytes / 8))
    .. NB.u16(0)
    .. NB.u16(ofsTexDict)
    .. NB.u16(0)
    .. NB.u32(ofsTex4x4Data)
    .. NB.u32(ofsTex4x4PlttIdx)
    .. NB.u32(0)
    .. NB.u16(math.floor(#palData / 8))
    .. NB.u16(0)
    .. NB.u16(ofsPlttDict)
    .. NB.u16(0)
    .. NB.u32(ofsPlttData)
  assert(#header == 0x3C, "TEX0 header must be 0x3C, got " .. #header)

  local block = header .. texDict .. pltDict .. texDataBytes .. tex4x4Bytes .. plttIdx .. palData
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
