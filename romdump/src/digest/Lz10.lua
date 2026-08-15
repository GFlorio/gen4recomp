-- LZ10 (LZSS) decompression as used by Nintendo DS resources: a 4-byte header
-- (0x10 marker plus a 24-bit little-endian output size), then flag bytes whose
-- bits are consumed most-significant first; a clear bit copies one literal
-- byte, a set bit copies a run from the already-decoded output (length = high
-- nibble + 3, displacement = low nibble * 256 + next byte + 1). The DS BIOS
-- LZ77UnCompWram implements the same scheme; GBATEK documents it under "DS
-- Files - LZSS, Yaz0, LZ11 - Decompression". Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")

local Lz10 = {}

-- Named ownership of the protocol error codes; tests assert the constants,
-- never the raw strings.
Lz10.ERROR = {
  HEADER_INVALID = "LZ10_HEADER_INVALID",
  STREAM_INVALID = "LZ10_STREAM_INVALID",
}

local HEADER_BYTES = 4
local MIN_MATCH_LENGTH = 3

-- Every source read is preceded by a bounds check: a stream that ends in the
-- middle of a token is malformed source, never a raw Lua indexing failure.
local function requireSource(bytes, src, count)
  if src + count - 1 > #bytes then
    Errors.raise(
      Lz10.ERROR.STREAM_INVALID,
      "LZ10 stream ends in the middle of a token",
      { src = src, needed = count, size = #bytes }
    )
  end
end

local function _decode(bytes)
  if #bytes < HEADER_BYTES or string.byte(bytes, 1) ~= 0x10 then
    Errors.raise(
      Lz10.ERROR.HEADER_INVALID,
      "LZ10 payload lacks the 0x10 header",
      { size = #bytes, first = #bytes >= 1 and string.byte(bytes, 1) or nil }
    )
  end
  local outputSize = string.byte(bytes, 2) + string.byte(bytes, 3) * 256 + string.byte(bytes, 4) * 65536
  local output = {}
  local src = HEADER_BYTES + 1
  local dst = 1
  while dst <= outputSize do
    requireSource(bytes, src, 1)
    local flags = string.byte(bytes, src)
    src = src + 1
    for bit = 7, 0, -1 do
      if dst > outputSize then
        break
      end
      if math.floor(flags / 2 ^ bit) % 2 == 0 then
        requireSource(bytes, src, 1)
        output[dst] = string.byte(bytes, src)
        src = src + 1
        dst = dst + 1
      else
        requireSource(bytes, src, 2)
        local b1 = string.byte(bytes, src)
        local b2 = string.byte(bytes, src + 1)
        src = src + 2
        local length = math.floor(b1 / 16) + MIN_MATCH_LENGTH
        local displacement = (b1 % 16) * 256 + b2 + 1
        if displacement > dst - 1 or output[dst - displacement] == nil then
          Errors.raise(
            Lz10.ERROR.STREAM_INVALID,
            "LZ10 match at output byte " .. dst .. " reaches before the decoded start",
            { dst = dst, displacement = displacement }
          )
        end
        if dst + length - 1 > outputSize then
          Errors.raise(
            Lz10.ERROR.STREAM_INVALID,
            "LZ10 match at output byte " .. dst .. " extends past the declared output size",
            { dst = dst, length = length, outputSize = outputSize }
          )
        end
        for _ = 1, length do
          output[dst] = output[dst - displacement]
          dst = dst + 1
        end
      end
    end
  end
  local chunks = {}
  for i = 1, outputSize do
    chunks[i] = string.char(output[i])
  end
  return table.concat(chunks)
end

---@param bytes string
---@return string?
---@return Errors.Error?
function Lz10.decode(bytes)
  assert(type(bytes) == "string", "Lz10.decode requires a string")
  local ok, result = pcall(_decode, bytes)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return Lz10
