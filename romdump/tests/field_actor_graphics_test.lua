-- Synthetic tests for the overlay 1 field-actor tables. Verifies six-byte record
-- recovery, the 5/5/6 packed partition, terminator handling, key-table and
-- animation-range decoding, and every rejection the reader owes its caller. No
-- ROM bytes are involved.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Fixture = require("tests.support.FieldActorFixture")
local FieldActorGraphics = require("romdump.src.digest.FieldActorGraphics")

local T = {}

local function decode(opts)
  return FieldActorGraphics.decode(Fixture.sampleOverlay(opts))
end

local function failsWith(code, opts)
  local result, err = decode(opts)
  Assert.isNil(result)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(assert(err).code, code)
end

function T.decodes_records_in_table_order()
  local decoded = assert(decode())
  Assert.equal(decoded.recordCount, 3)
  Assert.equal(decoded.records[1].spriteId, 0)
  Assert.equal(decoded.records[1].mapModelId, 69)
  Assert.equal(decoded.records[2].spriteId, 29)
  Assert.equal(decoded.records[3].spriteId, 1032)
  Assert.equal(decoded.bySpriteId[1032].mapModelId, 483)
end

function T.record_offsets_are_relative_to_the_table_start()
  local decoded = assert(decode())
  Assert.equal(decoded.records[1].offset, 0)
  Assert.equal(decoded.records[3].offset, 12)
  Assert.equal(decoded.terminatorOffset, 18)
  Assert.equal(decoded.spanBytes, 24)
end

function T.packed_word_splits_into_movement_family_and_visual()
  Assert.deepEqual(
    FieldActorGraphics.splitPacked(0x0000),
    { movementProfile = 0, actorFamily = 0, visualDescriptor = 0 }
  )
  Assert.deepEqual(
    FieldActorGraphics.splitPacked(0x1C60),
    { movementProfile = 0, actorFamily = 3, visualDescriptor = 7 }
  )
  Assert.deepEqual(
    FieldActorGraphics.splitPacked(0x4E27),
    { movementProfile = 7, actorFamily = 17, visualDescriptor = 19 }
  )
  -- The three fields together account for every bit of the word.
  Assert.equal(0x4E27 % 32 + math.floor(0x4E27 / 32) % 32 * 32 + math.floor(0x4E27 / 1024) * 1024, 0x4E27)
end

function T.expected_count_and_terminator_offset_are_enforced()
  assert(decode({ expectedRecordCount = 3, expectedTerminatorOffset = 18 }))
  failsWith("FIELD_ACTOR_RECORD_COUNT_MISMATCH", { expectedRecordCount = 4 })
  failsWith("FIELD_ACTOR_TERMINATOR_MISPLACED", { expectedTerminatorOffset = 24 })
end

function T.rejects_duplicate_sprite_id()
  failsWith("FIELD_ACTOR_DUPLICATE_SPRITE_ID", {
    records = {
      { spriteId = 7, mapModelId = 1, packed = 0 },
      { spriteId = 7, mapModelId = 2, packed = 0 },
    },
  })
end

function T.rejects_missing_terminator()
  failsWith("FIELD_ACTOR_TABLE_UNTERMINATED", { omitTerminator = true })
end

function T.rejects_table_address_outside_the_overlay()
  local bytes, locator, manifest = Fixture.sampleOverlay()
  manifest.tables.graphics.address = locator.ramAddress + #bytes + 4
  local result, err = FieldActorGraphics.decode(bytes, locator, manifest)
  Assert.isNil(result)
  Assert.equal(assert(err).code, "FIELD_ACTOR_ADDRESS_OUT_OF_OVERLAY")
end

function T.key_tables_resolve_descriptor_members()
  local decoded = assert(decode())
  Assert.equal(decoded.modelMembers.byKey[3], 266)
  Assert.equal(decoded.timelineMembers.byKey[4], 280)
  Assert.equal(decoded.descriptors[0].modelMemberId, 266)
  Assert.equal(decoded.descriptors[0].timelineMemberId, 280)
end

function T.rejects_duplicate_and_unmapped_keys()
  failsWith(
    "FIELD_ACTOR_DUPLICATE_KEY",
    { modelKeys = {
      { key = 3, memberId = 266 },
      { key = 3, memberId = 267 },
    } }
  )
  failsWith("FIELD_ACTOR_MODEL_KEY_UNKNOWN", { modelKeys = { { key = 9, memberId = 266 } } })
  failsWith("FIELD_ACTOR_TIMELINE_KEY_UNKNOWN", { timelineKeys = { { key = 9, memberId = 280 } } })
end

function T.animation_ranges_stop_at_the_zero_record()
  local decoded = assert(decode())
  local ranges = decoded.descriptors[0].ranges
  Assert.equal(#ranges, 4)
  Assert.equal(ranges[1].startFrame, 0)
  Assert.equal(ranges[1].endFrame, 15)
  Assert.equal(ranges[4].startFrame, 48)
  Assert.isTrue(ranges[1].loop, "endMode 0 wraps")
end

function T.clamping_end_mode_is_preserved()
  local decoded = assert(decode({ ranges = {
    { startFrame = 0, endFrame = 19, endMode = 1 },
  } }))
  Assert.equal(decoded.descriptors[0].ranges[1].endMode, 1)
  Assert.isFalse(decoded.descriptors[0].ranges[1].loop)
end

function T.rejects_inverted_range()
  failsWith("FIELD_ACTOR_RANGE_INVERTED", { ranges = { { startFrame = 30, endFrame = 10 } } })
end

function T.resolve_reports_absent_sprite_and_unknown_descriptor()
  local decoded = assert(decode())
  local resolved = assert(FieldActorGraphics.resolve(decoded, 0))
  Assert.equal(resolved.record.mapModelId, 69)
  Assert.equal(resolved.descriptor.timelineMemberId, 280)

  local missing, err = FieldActorGraphics.resolve(decoded, 101)
  Assert.isNil(missing)
  Assert.equal(assert(err).code, "FIELD_ACTOR_SPRITE_ABSENT")

  local other = assert(decode({
    records = {
      { spriteId = 5, mapModelId = 1, packed = 0x0400 }, -- selects descriptor 1
    },
  }))
  local unknown, descErr = FieldActorGraphics.resolve(other, 5)
  Assert.isNil(unknown)
  Assert.equal(assert(descErr).code, "FIELD_ACTOR_DESCRIPTOR_UNKNOWN")
end

return T
