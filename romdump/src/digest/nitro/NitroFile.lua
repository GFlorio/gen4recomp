-- Decoder for the common Nitro 3D container header shared by BMD0 (NSBMD) and
-- BTX0 (NSBTX) files. Layout is NNSG3dResFileHeader in pokeheartgold
-- lib/include/nnsys/g3d/binres/res_struct.h: a 16-byte header followed by a
-- u32 table of section offsets, each pointing at an NNSG3dResDataBlockHeader
-- (4-char kind + u32 size). Pure domain module; decode returns (file | nil,
-- err) at the public boundary and preserves unknown sections rather than
-- discarding them.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local NitroFile = {}

local BYTE_ORDER_MARK = 0xFEFF
local HEADER_SIZE = 0x10

local function raise(code, message, context)
  error(Errors.new(code, message, context))
end

local function _decode(bytes, expectedMagic, context)
  assert(type(bytes) == "string", "NitroFile.decode requires a string")
  if #bytes < HEADER_SIZE then
    raise(
      "NITRO_FILE_TOO_SMALL",
      string.format("file is %d bytes, need at least %d for a header", #bytes, HEADER_SIZE),
      { size = #bytes, source = context }
    )
  end
  local r = BinaryReader.new(bytes, "nitro-file")
  local magic = r:ascii(0x00, 4)
  if expectedMagic and magic ~= expectedMagic then
    raise(
      "NITRO_FILE_BAD_MAGIC",
      string.format("expected magic %q, got %q", expectedMagic, magic),
      { magic = magic, expected = expectedMagic, source = context }
    )
  end
  local bom = r:u16le(0x04)
  if bom ~= BYTE_ORDER_MARK then
    raise(
      "NITRO_FILE_BAD_BOM",
      string.format("expected byte-order mark 0x%04X, got 0x%04X", BYTE_ORDER_MARK, bom),
      { bom = bom, source = context }
    )
  end
  local fileSize = r:u32le(0x08)
  if fileSize ~= #bytes then
    raise(
      "NITRO_FILE_BAD_SIZE",
      string.format("header file size %d does not match input length %d", fileSize, #bytes),
      { fileSize = fileSize, actual = #bytes, source = context }
    )
  end
  local headerSize = r:u16le(0x0C)
  local sectionCount = r:u16le(0x0E)

  local sections = {}
  local prevOffset = -1
  for i = 0, sectionCount - 1 do
    local offset = r:u32le(HEADER_SIZE + i * 4)
    if offset <= prevOffset then
      raise(
        "NITRO_FILE_BAD_SECTION_ORDER",
        string.format("section %d offset 0x%X does not increase past 0x%X", i, offset, prevOffset),
        { index = i, offset = offset, previous = prevOffset, source = context }
      )
    end
    if offset + 8 > #bytes then
      raise(
        "NITRO_FILE_SECTION_OUT_OF_BOUNDS",
        string.format("section %d header at 0x%X exceeds %d-byte file", i, offset, #bytes),
        { index = i, offset = offset, size = #bytes, source = context }
      )
    end
    local kind = r:ascii(offset, 4)
    local size = r:u32le(offset + 4)
    if size < 8 or offset + size > #bytes then
      raise(
        "NITRO_FILE_SECTION_BAD_SIZE",
        string.format("section %d %q size %d at 0x%X exceeds %d-byte file", i, kind, size, offset, #bytes),
        { index = i, kind = kind, offset = offset, sectionSize = size, size = #bytes, source = context }
      )
    end
    sections[#sections + 1] = {
      index = i,
      magic = kind,
      offset = offset,
      size = size,
      bytes = r:bytes(offset, size),
    }
    prevOffset = offset
  end

  return {
    magic = magic,
    bom = bom,
    version = r:u16le(0x06),
    fileSize = fileSize,
    headerSize = headerSize,
    sections = sections,
    source = context,
  }
end

-- Returns a section by 4-char magic, or nil. Duplicate magic returns the first.
function NitroFile.section(file, magic)
  for _, s in ipairs(file.sections) do
    if s.magic == magic then
      return s
    end
  end
  return nil
end

function NitroFile.decode(bytes, expectedMagic, context)
  local ok, result = pcall(_decode, bytes, expectedMagic, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return NitroFile
