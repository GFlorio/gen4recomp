-- Deterministic PNG encoder for generated textures. Emits a truecolor-alpha
-- (8-bit RGBA) PNG with a single zlib stream of stored (uncompressed) DEFLATE
-- blocks and no ancillary chunks or timestamps, so identical pixels always
-- produce byte-identical files -- a requirement for content-addressed derived
-- assets. Pure Lua; the only dependency is LuaJIT's builtin `bit` module for the
-- CRC-32 (available under bare LuaJIT and LÖVE alike). Format per the PNG (RFC
-- 2083) and zlib/DEFLATE (RFC 1950/1951) specifications.

local bit = require("bit")
local Errors = require("libs.rom.src.Errors")

local PngWriter = {}

local SIGNATURE = string.char(137, 80, 78, 71, 13, 10, 26, 10)

local CRC_TABLE = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then
      c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
    else
      c = bit.rshift(c, 1)
    end
  end
  CRC_TABLE[n] = c
end

local function crc32(s)
  local crc = bit.bnot(0)
  for i = 1, #s do
    crc = bit.bxor(bit.rshift(crc, 8), CRC_TABLE[bit.band(bit.bxor(crc, string.byte(s, i)), 0xFF)])
  end
  return bit.bnot(crc)
end

-- Big-endian u32 from any 32-bit value (bit ops normalize to 32 bits).
local function be32(x)
  return string.char(
    bit.band(bit.rshift(x, 24), 0xFF),
    bit.band(bit.rshift(x, 16), 0xFF),
    bit.band(bit.rshift(x, 8), 0xFF),
    bit.band(x, 0xFF)
  )
end

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + string.byte(s, i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

-- Wrap raw bytes in stored (BTYPE=00) DEFLATE blocks of up to 65535 bytes.
local function storedDeflate(raw)
  local out, n, pos = {}, #raw, 1
  repeat
    local block = raw:sub(pos, pos + 65534)
    pos = pos + #block
    local final = (pos > n) and 1 or 0
    local len = #block
    local nlen = 65535 - len
    out[#out + 1] = string.char(final)
    out[#out + 1] = string.char(len % 256, math.floor(len / 256))
    out[#out + 1] = string.char(nlen % 256, math.floor(nlen / 256))
    out[#out + 1] = block
  until pos > n
  return table.concat(out)
end

local function chunk(typ, data)
  return be32(#data) .. typ .. data .. be32(crc32(typ .. data))
end

-- rgba: width*height*4 bytes, row-major, top-left origin, straight alpha.
function PngWriter.encode(width, height, rgba)
  if #rgba ~= width * height * 4 then
    Errors.raise(
      "PNG_BAD_RGBA_LENGTH",
      string.format("rgba is %d bytes, expected %d (%dx%d*4)", #rgba, width * height * 4, width, height),
      { width = width, height = height, length = #rgba }
    )
  end

  local ihdr = be32(width) .. be32(height) .. string.char(8, 6, 0, 0, 0)

  local rows = {}
  for y = 0, height - 1 do
    rows[#rows + 1] = "\0" -- filter type 0 (none)
    rows[#rows + 1] = rgba:sub(y * width * 4 + 1, (y + 1) * width * 4)
  end
  local raw = table.concat(rows)
  local zlib = string.char(0x78, 0x01) .. storedDeflate(raw) .. be32(adler32(raw))

  return SIGNATURE .. chunk("IHDR", ihdr) .. chunk("IDAT", zlib) .. chunk("IEND", "")
end

return PngWriter
