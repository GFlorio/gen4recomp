-- Test helper: build a minimal STORED (uncompressed) .zip in memory so zip-ROM
-- support can be exercised without a real archive. PhysFS/love.filesystem mounts
-- the result. CRC32s are computed properly via LuaJIT's bit module, not
-- 5.3 bitwise syntax. files = { { name = "a/b.nds", data = "..." }, ... }.

local bit = require("bit")

local ZipBuilder = {}

local function u16(v)
  return string.char(bit.band(v, 0xFF), bit.band(bit.rshift(v, 8), 0xFF))
end

local function u32(v)
  return string.char(
    bit.band(v, 0xFF),
    bit.band(bit.rshift(v, 8), 0xFF),
    bit.band(bit.rshift(v, 16), 0xFF),
    bit.band(bit.rshift(v, 24), 0xFF)
  )
end

local CRC_TABLE
local function crcTable()
  if CRC_TABLE then
    return CRC_TABLE
  end
  CRC_TABLE = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      local mask = -bit.band(c, 1) -- 0x00000000 or 0xFFFFFFFF
      c = bit.bxor(bit.rshift(c, 1), bit.band(0xEDB88320, mask))
    end
    CRC_TABLE[i] = c
  end
  return CRC_TABLE
end

local function crc32(data)
  local t = crcTable()
  local crc = 0xFFFFFFFF
  for i = 1, #data do
    local idx = bit.band(bit.bxor(crc, data:byte(i)), 0xFF)
    crc = bit.bxor(bit.rshift(crc, 8), t[idx])
  end
  return bit.band(bit.bxor(crc, 0xFFFFFFFF), 0xFFFFFFFF)
end

function ZipBuilder.build(files)
  local locals, central = {}, {}
  local offset = 0
  for _, f in ipairs(files) do
    local crc = crc32(f.data)
    local size = #f.data
    local localHeader = u32(0x04034b50)
      .. u16(20)
      .. u16(0)
      .. u16(0)
      .. u16(0)
      .. u16(0)
      .. u32(crc)
      .. u32(size)
      .. u32(size)
      .. u16(#f.name)
      .. u16(0)
      .. f.name
    locals[#locals + 1] = localHeader .. f.data

    central[#central + 1] = u32(0x02014b50)
      .. u16(20)
      .. u16(20)
      .. u16(0)
      .. u16(0)
      .. u16(0)
      .. u16(0)
      .. u32(crc)
      .. u32(size)
      .. u32(size)
      .. u16(#f.name)
      .. u16(0)
      .. u16(0)
      .. u16(0)
      .. u16(0)
      .. u32(0)
      .. u32(offset)
      .. f.name
    offset = offset + #localHeader + size
  end

  local localBytes = table.concat(locals)
  local centralBytes = table.concat(central)
  local eocd = u32(0x06054b50)
    .. u16(0)
    .. u16(0)
    .. u16(#files)
    .. u16(#files)
    .. u32(#centralBytes)
    .. u32(#localBytes)
    .. u16(0)
  return localBytes .. centralBytes .. eocd
end

return ZipBuilder
