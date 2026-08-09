-- Decodes the backwards LZ stream used by compressed Nintendo DS overlays.
-- The footer and overlay-table flag semantics follow GBATEK's DS overlay file
-- format. Uncompressed overlays are returned unchanged by the caller.

local BinaryReader = require("libs.rom.src.BinaryReader")
local Errors = require("libs.rom.src.Errors")

local OverlayCompression = {}

-- GBATEK DS overlay footer: one u32 whose top 8 bits hold the compressed
-- header length and bottom 24 bits the packed length.
local HEADER_LENGTH_BITS = 24
local FOOTER_BYTES = 8

-- Backwards-LZ match token: the first byte's high nibble is (length - 3) and
-- its low nibble with the following byte is (displacement - 3).
local MATCH_LENGTH_NIBBLE_BITS = 4
local MIN_MATCH_LENGTH = 3
local MIN_DISPLACEMENT = 3

local function _decode(bytes, expectedSize)
  assert(type(bytes) == "string", "overlay bytes must be a string")
  if #bytes < FOOTER_BYTES then
    Errors.raise(
      "OVERLAY_COMPRESSION_HEADER_INVALID",
      "compressed overlay is shorter than its footer",
      { size = #bytes }
    )
  end
  local reader = BinaryReader.new(bytes, "compressed-overlay")
  local header = reader:u32le(#bytes - FOOTER_BYTES)
  local packedLength = header % (2 ^ HEADER_LENGTH_BITS)
  local headerLength = math.floor(header / (2 ^ HEADER_LENGTH_BITS))
  local addedLength = reader:u32le(#bytes - 4)
  if headerLength < 8 or packedLength > #bytes or packedLength < headerLength then
    Errors.raise(
      "OVERLAY_COMPRESSION_HEADER_INVALID",
      "invalid backwards-LZ footer",
      { size = #bytes, headerLength = headerLength, packedLength = packedLength }
    )
  end
  local outputLength = #bytes + addedLength
  if expectedSize and outputLength ~= expectedSize then
    Errors.raise(
      "OVERLAY_COMPRESSION_SIZE_MISMATCH",
      "decompressed overlay size " .. outputLength .. " ~= expected " .. expectedSize,
      { actual = outputLength, expected = expectedSize }
    )
  end

  local output = {}
  local rawPrefixLength = #bytes - packedLength
  for offset = 0, rawPrefixLength - 1 do
    output[offset] = string.byte(bytes, offset + 1)
  end
  local sourceOffset = #bytes - headerLength - 1
  local outputOffset = outputLength - 1
  while sourceOffset >= rawPrefixLength and outputOffset >= rawPrefixLength do
    local flags = string.byte(bytes, sourceOffset + 1)
    sourceOffset = sourceOffset - 1
    local mask = 128
    while mask > 0 and outputOffset >= rawPrefixLength do
      if flags % (mask * 2) >= mask then
        if sourceOffset - 1 < rawPrefixLength then
          Errors.raise("OVERLAY_COMPRESSION_STREAM_INVALID", "truncated backwards-LZ match", {})
        end
        local first = string.byte(bytes, sourceOffset + 1)
        local second = string.byte(bytes, sourceOffset)
        sourceOffset = sourceOffset - 2
        local length = math.floor(first / (2 ^ MATCH_LENGTH_NIBBLE_BITS)) + MIN_MATCH_LENGTH
        local displacement = (first % (2 ^ MATCH_LENGTH_NIBBLE_BITS)) * 256 + second + MIN_DISPLACEMENT
        for _ = 1, length do
          local copyOffset = outputOffset + displacement
          if copyOffset >= outputLength or output[copyOffset] == nil then
            Errors.raise(
              "OVERLAY_COMPRESSION_STREAM_INVALID",
              "backwards-LZ match is out of bounds",
              { outputOffset = outputOffset, displacement = displacement }
            )
          end
          output[outputOffset] = output[copyOffset]
          outputOffset = outputOffset - 1
          if outputOffset < rawPrefixLength then
            break
          end
        end
      else
        if sourceOffset < rawPrefixLength then
          Errors.raise("OVERLAY_COMPRESSION_STREAM_INVALID", "truncated backwards-LZ literal", {})
        end
        output[outputOffset] = string.byte(bytes, sourceOffset + 1)
        sourceOffset = sourceOffset - 1
        outputOffset = outputOffset - 1
      end
      mask = math.floor(mask / 2)
    end
  end
  if outputOffset >= rawPrefixLength then
    Errors.raise(
      "OVERLAY_COMPRESSION_STREAM_INVALID",
      "backwards-LZ stream ended early",
      { remaining = outputOffset - rawPrefixLength + 1 }
    )
  end
  local chunks = {}
  for offset = 0, outputLength - 1 do
    chunks[offset + 1] = string.char(output[offset])
  end
  return table.concat(chunks)
end

function OverlayCompression.decode(bytes, expectedSize)
  local ok, result = pcall(_decode, bytes, expectedSize)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return OverlayCompression
