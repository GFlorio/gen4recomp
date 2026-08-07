-- Builds synthetic Nitro 3D byte blobs for unit tests: little-endian integer
-- packers, a resource dictionary matching NNSG3dResDict, and a BMD0/BTX0
-- container matching NNSG3dResFileHeader. Keeps binary fixtures out of the
-- repo while exercising the real byte layouts the decoders expect.

local NitroBuilder = {}

function NitroBuilder.u8(v) return string.char(v % 256) end

function NitroBuilder.u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

function NitroBuilder.u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- Pad/truncate a name to a fixed 16-byte NUL-padded field.
local function name16(name)
  assert(#name <= 16, "dictionary name exceeds 16 bytes: " .. name)
  return name .. string.rep("\0", 16 - #name)
end

-- entries: array of { name = string, data = string (all equal length) }.
-- Produces a valid NNSG3dResDict with a zeroed Patricia tree (the decoder does
-- not walk it) and a self-describing sizeUnit.
function NitroBuilder.dict(entries)
  local u8, u16 = NitroBuilder.u8, NitroBuilder.u16
  local count = #entries
  local sizeUnit = count > 0 and #entries[1].data or 0
  for _, e in ipairs(entries) do
    assert(#e.data == sizeUnit, "dict entries must share one data size")
  end

  local tree = string.rep("\0", (count + 1) * 4) -- N+1 nodes, contents unused
  local ofsEntry = 8 + #tree
  local dataBlock = {}
  for _, e in ipairs(entries) do dataBlock[#dataBlock + 1] = e.data end
  local data = table.concat(dataBlock)
  local ofsName = 4 + #data -- names follow the data, relative to entry header
  local names = {}
  for _, e in ipairs(entries) do names[#names + 1] = name16(e.name) end
  local nameBlock = table.concat(names)

  local entrySection = u16(sizeUnit) .. u16(ofsName) .. data .. nameBlock
  local body = u8(0) .. u8(count) .. u16(0) .. u16(0) .. u16(ofsEntry) .. tree .. entrySection
  -- Patch sizeDictBlk to the real total size.
  return u8(0) .. u8(count) .. u16(#body) .. body:sub(5)
end

-- sections: array of { magic = 4-char string, body = string } where body is the
-- payload AFTER the 8-byte block header. Produces a valid container file.
function NitroBuilder.file(magic, sections)
  local u16, u32 = NitroBuilder.u16, NitroBuilder.u32
  assert(#magic == 4, "file magic must be 4 bytes")
  local headerSize = 0x10
  local tableSize = #sections * 4
  local sectionStart = headerSize + tableSize

  local offsets = {}
  local blocks = {}
  local cursor = sectionStart
  for _, s in ipairs(sections) do
    assert(#s.magic == 4, "section magic must be 4 bytes")
    offsets[#offsets + 1] = cursor
    local block = s.magic .. u32(8 + #s.body) .. s.body
    blocks[#blocks + 1] = block
    cursor = cursor + #block
  end

  local fileSize = cursor
  local offsetTable = {}
  for _, o in ipairs(offsets) do offsetTable[#offsetTable + 1] = u32(o) end

  return magic
    .. u16(0xFEFF) .. u16(0) .. u32(fileSize)
    .. u16(headerSize) .. u16(#sections)
    .. table.concat(offsetTable)
    .. table.concat(blocks)
end

return NitroBuilder
