-- NSBTX / TEX0 decoder. Handles both standalone BTX0 files and TEX0 sections
-- embedded in a BMD0 through one path (decodeTex0 takes the raw TEX0 block).
--
-- TEX0 block layout (NNSG3dResTex, res_struct.h), offsets from the block start:
--   +0x0C u16 sizeTex        ; texel data size, in 8-byte units
--   +0x0E u16 ofsTexDict
--   +0x14 u32 ofsTexData
--   +0x1C u16 sizeTex4x4     ; compressed texel size, 8-byte units
--   +0x24 u32 ofsTex4x4Data
--   +0x28 u32 ofsTex4x4PlttIdx
--   +0x30 u16 sizePltt       ; palette data size, 8-byte units
--   +0x34 u16 ofsPlttDict
--   +0x38 u32 ofsPlttData
--
-- Each texture dict data unit is the GX TEXIMAGE_PARAM word (bits: 0-15 texel
-- offset in 8-byte units, 16-17 repeat S/T, 18-19 flip S/T, 20-22 size S,
-- 23-25 size T, 26-28 format, 29 color0-transparent, 30-31 coord transform) in
-- its low u32; the trailing 4 bytes are preserved raw. Each palette dict unit
-- is a u16 offset (8-byte units) plus a u16 flag. All sizes/offsets verified
-- against the real HGSS map texture pack. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
local NitroFile = require("romdump.src.digest.nitro.NitroFile")
local NitroDict = require("romdump.src.digest.nitro.NitroDict")

local Nsbtx = {}

local FORMAT_NAMES = {
  [0] = "none",
  [1] = "a3i5",
  [2] = "palette4",
  [3] = "palette16",
  [4] = "palette256",
  [5] = "compressed4x4",
  [6] = "a5i3",
  [7] = "direct",
}

-- Texel data size in bytes for a width*height texture in the given format.
local function texelBytes(format, width, height)
  local texels = width * height
  if format == 1 or format == 4 or format == 6 then
    return texels
  end
  if format == 2 then
    return math.floor(texels / 4)
  end
  if format == 3 then
    return math.floor(texels / 2)
  end
  if format == 5 then
    return math.floor(texels / 4)
  end
  if format == 7 then
    return texels * 2
  end
  return 0
end

local function decodeTextureUnit(index, name, data, dataOffset)
  local r = BinaryReader.new(data, "tex-unit")
  local param = r:u32le(0)
  local texelOffset = (param % 0x10000) * 8
  local repeatS = math.floor(param / 0x10000) % 2
  local repeatT = math.floor(param / 0x20000) % 2
  local flipS = math.floor(param / 0x40000) % 2
  local flipT = math.floor(param / 0x80000) % 2
  local sizeS = math.floor(param / 0x100000) % 8
  local sizeT = math.floor(param / 0x800000) % 8
  local format = math.floor(param / 0x4000000) % 8
  local color0 = math.floor(param / 0x20000000) % 2
  local coordXf = math.floor(param / 0x40000000) % 4
  local width = 8 * 2 ^ sizeS
  local height = 8 * 2 ^ sizeT
  return {
    index = index,
    name = name,
    formatRaw = format,
    format = FORMAT_NAMES[format] or "unknown",
    width = width,
    height = height,
    color0Transparent = color0 == 1,
    repeatX = repeatS == 1,
    repeatY = repeatT == 1,
    flipX = flipS == 1,
    flipY = flipT == 1,
    coordinateTransformMode = coordXf,
    texelOffset = texelOffset, -- byte offset within the format's texel block
    dataSize = texelBytes(format, width, height),
    param = param,
    extra = data:sub(5),
    dataOffset = dataOffset,
  }
end

local function decodePaletteUnit(index, name, data, dataOffset)
  local r = BinaryReader.new(data, "pltt-unit")
  local offsetUnits = r:u16le(0)
  return {
    index = index,
    name = name,
    dataOffset = offsetUnits * 8, -- byte offset within the palette block
    flag = r:u16le(2),
    dictOffset = dataOffset,
  }
end

-- bytes: a TEX0 block starting with the 4-char kind + u32 size header.
local function _decodeTex0(bytes, context)
  local r = BinaryReader.new(bytes, "tex0")
  local kind = r:ascii(0, 4)
  if kind ~= "TEX0" then
    error(
      Errors.new(
        "NSBTX_BAD_MAGIC",
        string.format("expected TEX0 block, got %q", kind),
        { magic = kind, source = context }
      )
    )
  end

  local ofsTexDict = r:u16le(0x0E)
  local ofsTexData = r:u32le(0x14)
  local ofsTex4x4Data = r:u32le(0x24)
  local ofsTex4x4PlttIdx = r:u32le(0x28)
  local ofsPlttDict = r:u16le(0x34)
  local ofsPlttData = r:u32le(0x38)
  local sizePltt = r:u16le(0x30) * 8 -- palette block size, stored in 8-byte units

  local texDict = assert(NitroDict.decode(bytes, ofsTexDict, context))
  local plttDict = assert(NitroDict.decode(bytes, ofsPlttDict, context))

  local textures, textureByName = {}, {}
  for _, e in ipairs(texDict.entries) do
    local t = decodeTextureUnit(e.index, e.name, e.data, e.dataOffset)
    -- Absolute texel offset differs for the 4x4-compressed block.
    if t.formatRaw == 5 then
      t.dataAbsolute = ofsTex4x4Data + t.texelOffset
      t.compressedInfoOffset = ofsTex4x4PlttIdx + math.floor(t.texelOffset / 2)
    else
      t.dataAbsolute = ofsTexData + t.texelOffset
    end
    textures[#textures + 1] = t
    textureByName[t.name] = t
  end

  local palettes, paletteByName = {}, {}
  for _, e in ipairs(plttDict.entries) do
    local p = decodePaletteUnit(e.index, e.name, e.data, e.dataOffset)
    p.dataAbsolute = ofsPlttData + p.dataOffset
    palettes[#palettes + 1] = p
    paletteByName[p.name] = p
  end

  return {
    textures = textures,
    palettes = palettes,
    textureByName = textureByName,
    paletteByName = paletteByName,
    offsets = {
      texData = ofsTexData,
      tex4x4Data = ofsTex4x4Data,
      tex4x4PlttIdx = ofsTex4x4PlttIdx,
      plttData = ofsPlttData,
      plttDataEnd = ofsPlttData + sizePltt,
    },
    bytes = bytes, -- retained so TextureDecoder can slice texel/palette data
    source = context,
  }
end

function Nsbtx.decodeTex0(bytes, context)
  local ok, result = pcall(_decodeTex0, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

-- Standalone BTX0 file -> TEX0 inventory.
function Nsbtx.decode(bytes, context)
  local file, err = NitroFile.decode(bytes, "BTX0", context)
  if not file then
    return nil, err
  end
  local section = NitroFile.section(file, "TEX0")
  if not section then
    return nil, Errors.new("NSBTX_NO_TEX0", "BTX0 file has no TEX0 section", { source = context })
  end
  return Nsbtx.decodeTex0(section.bytes, context)
end

-- Bridge a decoded texture (+ its palette, if paletted) to TextureDecoder opts
-- by slicing the retained pack bytes. The texel slice is exact; the palette
-- slice runs to the palette block end (over-inclusive but bounded), since a
-- record carries no explicit length and the decoder indexes only what it needs.
-- Direct-color (format 7) needs no palette.
function Nsbtx.decoderOpts(pack, texture, palette)
  local b = pack.bytes
  local opts = {
    format = texture.formatRaw,
    width = texture.width,
    height = texture.height,
    color0Transparent = texture.color0Transparent,
    texel = b:sub(texture.dataAbsolute + 1, texture.dataAbsolute + texture.dataSize),
  }
  if palette then
    local pend = pack.offsets.plttDataEnd or #b
    opts.palette = b:sub(palette.dataAbsolute + 1, pend)
  else
    opts.palette = ""
  end
  if texture.formatRaw == 5 then
    -- 4x4-compressed: one u16 control word per 4x4 block == texels/8 == dataSize/2.
    local n = math.floor(texture.dataSize / 2)
    opts.indexData = b:sub(texture.compressedInfoOffset + 1, texture.compressedInfoOffset + n)
  end
  return opts
end

Nsbtx.FORMAT_NAMES = FORMAT_NAMES

return Nsbtx
