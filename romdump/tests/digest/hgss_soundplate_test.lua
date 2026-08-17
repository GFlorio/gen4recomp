-- Decoder contract for the HGSS land BGS soundplate block (the SoundplateStruct
-- recovered from the field engine's field_control.c): the 0x1234 signature
-- bytes, a little-endian u16 recordBytes at offset 2, then 8-byte Soundplate
-- records. The decode requires at least four block bytes, a record-byte
-- count divisible by 8, and the record block spanning the block exactly
-- (the ROM census proved the real archives have no trailing bytes); it decodes
-- exactly recordBytes/8 records from offset 4 and drops every byte it does
-- not need (the signature and the two unknown record bytes) so a producer IR
-- record carries only soundplateSoundID, volumeIndex, and the inclusive
-- rectangle fields x/z/xBounds/zBounds. Malformed payloads raise structured
-- SOUNDPLATE_* errors carrying the caller's source context.

local Assert = require("tests.support.Assert")
local HgssSoundplate = require("romdump.src.digest.HgssSoundplate")
local Builder = require("tests.support.SoundplateBuilder")

local T = {}

function T.decodes_an_empty_record_block()
  local records = assert(HgssSoundplate.decode("\0\0\0\0"))
  Assert.deepEqual(records, {})
end

function T.decodes_one_record_and_preserves_the_inclusive_rectangle_fields_exactly()
  local records = assert(HgssSoundplate.decode(Builder.payload({
    records = {
      { soundId = 2, volumeIndex = 1, x = 7, z = 3, xBounds = 31, zBounds = 26 },
    },
  })))
  Assert.equal(#records, 1)
  Assert.deepEqual(records[1], {
    soundplateSoundID = 2,
    volumeIndex = 1,
    x = 7,
    z = 3,
    xBounds = 31,
    zBounds = 26,
  })
end

function T.decodes_multiple_records_in_source_order()
  local records = assert(HgssSoundplate.decode(Builder.payload({
    records = {
      { soundId = 0, volumeIndex = 0, x = 0, z = 0, xBounds = 1, zBounds = 1 },
      { soundId = 15, volumeIndex = 2, x = 4, z = 4, xBounds = 8, zBounds = 8 },
      { soundId = 9, volumeIndex = 3, x = 12, z = 20, xBounds = 16, zBounds = 24 },
    },
  })))
  Assert.equal(#records, 3)
  Assert.equal(records[1].soundplateSoundID, 0)
  Assert.equal(records[2].soundplateSoundID, 15)
  Assert.equal(records[2].xBounds, 8)
  Assert.equal(records[3].volumeIndex, 3)
  Assert.equal(records[3].z, 20)
end

local function decodeErr(payload, context)
  local records, err = HgssSoundplate.decode(payload, context)
  Assert.isNil(records)
  Assert.notNil(err)
  return assert(err)
end

function T.rejects_payloads_shorter_than_the_four_byte_header()
  for _, payload in ipairs({ "", "\0", "\0\0", "\0\0\0" }) do
    local err = decodeErr(payload)
    Assert.equal(err.code, "SOUNDPLATE_TOO_SHORT")
    Assert.equal(err.context.payloadSize, #payload)
  end
end

function T.rejects_record_byte_counts_not_divisible_by_eight()
  -- recordBytes 12 (not % 8 == 0) with a matching 12-byte record block, so the
  -- divisibility failure is the only malformation.
  local err = decodeErr(Builder.payload({ body = string.rep("\0", 12), recordBytes = 12 }))
  Assert.equal(err.code, "SOUNDPLATE_BAD_RECORD_BYTES")
  Assert.equal(err.context.recordBytes, 12)
  Assert.equal(err.context.payloadSize, 16)
end

function T.rejects_declared_record_bytes_running_past_the_payload()
  -- recordBytes 16 is a multiple of 8 but 4 + 16 outruns the 12-byte payload.
  local err = decodeErr(Builder.payload({ body = string.rep("\0", 8), recordBytes = 16 }))
  Assert.equal(err.code, "SOUNDPLATE_OVERFLOW")
  Assert.equal(err.context.recordBytes, 16)
  Assert.equal(err.context.payloadSize, 12)
end

function T.rejects_trailing_bytes_after_the_record_block()
  -- The ROM census proved every non-empty land BGS block ends right after its
  -- last record, so a payload with bytes after the declared record block is a
  -- malformation, not tolerated padding.
  local err = decodeErr(Builder.payload({
    records = { { soundId = 1, volumeIndex = 0, x = 0, z = 0, xBounds = 2, zBounds = 2 } },
    trailing = "\x01\x02\x03\x04\x05",
  }))
  Assert.equal(err.code, "SOUNDPLATE_TRAILING_BYTES")
  Assert.equal(err.context.recordBytes, 8)
  Assert.equal(err.context.payloadSize, 17)
end

function T.drops_the_signature_and_unknown_record_bytes()
  local records = assert(HgssSoundplate.decode(Builder.payload({
    headerUnknown = "\xAB\xCD",
    records = {
      { soundId = 5, volumeIndex = 2, x = 9, z = 2, xBounds = 16, zBounds = 10, unknown2 = 0xEE, unknown3 = 0xFD },
    },
  })))
  Assert.equal(#records, 1)
  Assert.deepEqual(records[1], {
    soundplateSoundID = 5,
    volumeIndex = 2,
    x = 9,
    z = 2,
    xBounds = 16,
    zBounds = 10,
  })
end

function T.errors_carry_the_callers_source_context()
  local err = decodeErr("\0\0\0", { mapId = 139, memberId = 244 })
  Assert.equal(err.code, "SOUNDPLATE_TOO_SHORT")
  Assert.equal(err.context.source.mapId, 139)
  Assert.equal(err.context.source.memberId, 244)
end

return { tests = T }
