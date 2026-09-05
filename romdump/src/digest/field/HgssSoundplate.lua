-- Decoder for the HGSS land BGS soundplate block (the engine's
-- SoundplateStruct, HGSS src/field/field_control.c): the 0x1234 BGS signature
-- bytes, a little-endian u16 recordBytes, then 8-byte Soundplate records.
-- LandData validates the signature when it unpacks the block; this decoder
-- only needs the record count and skips the signature. The ROM census proved
-- the record block always spans the whole block exactly (every non-empty land
-- BGS block in both retail archives ends right after its last record), so
-- trailing bytes are a malformation, not tolerated padding. Pure domain
-- module; decode() returns (records | nil, err).

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")

local HgssSoundplate = {}

local HEADER_SIZE = 4
local RECORD_SIZE = 8

local function fail(code, message, context, extra)
  extra = extra or {}
  extra.source = context
  Errors.raise(code, message, extra)
end

local function parse(bytes, context)
  if #bytes < HEADER_SIZE then
    fail(
      "SOUNDPLATE_TOO_SHORT",
      "soundplate payload is " .. #bytes .. " bytes, need at least " .. HEADER_SIZE,
      context,
      { payloadSize = #bytes }
    )
  end
  local r = BinaryReader.new(bytes, "soundplate")
  local recordBytes = r:u16le(2)
  if recordBytes % RECORD_SIZE ~= 0 then
    fail(
      "SOUNDPLATE_BAD_RECORD_BYTES",
      "record byte count " .. recordBytes .. " is not a multiple of " .. RECORD_SIZE,
      context,
      { recordBytes = recordBytes, payloadSize = #bytes }
    )
  end
  if HEADER_SIZE + recordBytes > #bytes then
    fail(
      "SOUNDPLATE_OVERFLOW",
      "record block of " .. recordBytes .. " bytes runs past the " .. #bytes .. "-byte payload",
      context,
      { recordBytes = recordBytes, payloadSize = #bytes }
    )
  end
  if HEADER_SIZE + recordBytes < #bytes then
    fail(
      "SOUNDPLATE_TRAILING_BYTES",
      "record block of "
        .. recordBytes
        .. " bytes leaves "
        .. (#bytes - (HEADER_SIZE + recordBytes))
        .. " trailing bytes",
      context,
      { recordBytes = recordBytes, payloadSize = #bytes }
    )
  end

  local records = {}
  for id = 0, recordBytes / RECORD_SIZE - 1 do
    local offset = HEADER_SIZE + id * RECORD_SIZE
    records[id + 1] = {
      soundplateSoundID = r:u8(offset),
      volumeIndex = r:u8(offset + 1),
      x = r:u8(offset + 4),
      z = r:u8(offset + 5),
      xBounds = r:u8(offset + 6),
      zBounds = r:u8(offset + 7),
    }
  end
  return records
end

function HgssSoundplate.decode(bytes, context)
  assert(type(bytes) == "string", "HgssSoundplate.decode requires a string")
  local ok, result = pcall(parse, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return HgssSoundplate
