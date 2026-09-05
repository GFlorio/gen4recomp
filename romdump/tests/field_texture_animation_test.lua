-- Parser tests for the HGSS field texture-animation table: the member-0
-- contents of `data/fldtanime.narc` in pret/pokeheartgold, a little-endian
-- u32 record count followed by fixed 52-byte records of a NUL-padded 16-byte
-- name and an 18-pair schedule. A schedule ends at the first pair whose
-- textureIndex is 0xFF (the duration byte is irrelevant); pairs after it are
-- ignored, live steps may carry a zero duration, the table needs at least the
-- bytes its declared records occupy (trailing bytes are ignored), and a record
-- whose first pair is the terminator is malformed. Error codes are exposed as
-- owner-local constants; tests reference the constants, never the literals.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldTextureAnimation = require("romdump.src.digest.field.FieldTextureAnimation")

local T = {}

local SOURCE = { alias = "field_texture_animations", memberId = 0 }

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function scheduleBytes(schedule)
  assert(#schedule == 18, "a record holds exactly 18 pairs")
  local out = {}
  for _, entry in ipairs(schedule) do
    out[#out + 1] = string.char(entry[1], entry[2])
  end
  return table.concat(out)
end

local function record(name, schedule)
  assert(#name <= 16, "a name fits the 16-byte fixed field")
  return name .. string.rep("\0", 16 - #name) .. scheduleBytes(schedule)
end

-- Pads a schedule with terminator pairs up to the 18-pair record width.
local function filled(schedule)
  local out = {}
  for _, entry in ipairs(schedule) do
    out[#out + 1] = entry
  end
  while #out < 18 do
    out[#out + 1] = { FieldTextureAnimation.TERMINATOR, FieldTextureAnimation.TERMINATOR }
  end
  return out
end

local function tableBytes(records)
  return u32(#records) .. table.concat(records)
end

local function parseErr(bytes)
  local records, err = FieldTextureAnimation.parse(bytes, SOURCE)
  Assert.isNil(records)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  return assert(err)
end

local function throws(code, fn)
  local err = parseErr(fn())
  Assert.equal(err.code, code)
  return err
end

function T.parses_one_valid_record_with_exact_zero_based_timeline()
  local bytes = tableBytes({
    record(
      "flower01",
      filled({
        { 0, 18 },
        { 1, 18 },
        { 0, 18 },
        { 2, 18 },
      })
    ),
  })
  local records, err = FieldTextureAnimation.parse(bytes, SOURCE)
  Assert.isNil(err)
  assert(records)
  Assert.equal(#records, 1)
  Assert.equal(records[1].index, 0)
  Assert.equal(records[1].name, "flower01")
  Assert.deepEqual(records[1].timeline, {
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 1, durationTicks = 18 },
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 2, durationTicks = 18 },
  })
end

-- The terminator is the textureIndex byte alone: the accompanying duration
-- byte (0xFF, 0x00, or anything else) never changes the outcome.
function T.terminates_on_ff_regardless_of_the_duration_byte()
  for _, terminator in ipairs({
    { 0xFF, 0xFF },
    { 0xFF, 0x00 },
    { 0xFF, 0x37 },
  }) do
    local records, err =
      FieldTextureAnimation.parse(tableBytes({ record("flower01", filled({ { 0, 6 }, terminator })) }), SOURCE)
    Assert.isNil(err)
    assert(records)
    Assert.deepEqual(records[1].timeline, { { textureIndex = 0, durationTicks = 6 } })
  end
end

-- HGSS never consumes schedule pairs after the terminator, so arbitrary
-- trailing pair data inside the fixed record is ignored, not rejected.
function T.ignores_pair_bytes_after_the_terminator()
  local records, err = FieldTextureAnimation.parse(
    tableBytes({
      record(
        "flower01",
        filled({
          { 0, 18 },
          { 1, 18 },
          { 0xFF, 0x7A },
          { 0xDE, 0xAD },
          { 0xBE, 0xEF },
          { 0x00, 0x12 },
        })
      ),
    }),
    SOURCE
  )
  Assert.isNil(err)
  assert(records)
  Assert.deepEqual(records[1].timeline, {
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 1, durationTicks = 18 },
  })
end

-- The original state machine can process a zero duration, so the parser must
-- not invent a stronger constraint than the source imposes.
function T.accepts_a_zero_duration_live_step()
  local records, err =
    FieldTextureAnimation.parse(tableBytes({ record("flower01", filled({ { 0, 0 }, { 1, 18 } })) }), SOURCE)
  Assert.isNil(err)
  assert(records)
  Assert.deepEqual(records[1].timeline, {
    { textureIndex = 0, durationTicks = 0 },
    { textureIndex = 1, durationTicks = 18 },
  })
end

-- The table needs enough bytes for its declared records; anything beyond is
-- trailing member data the parser ignores.
function T.ignores_trailing_bytes_after_the_declared_records()
  local valid = tableBytes({ record("sea_on", filled({ { 0, 6 } })) })
  local records, err = FieldTextureAnimation.parse(valid .. "\0tail", SOURCE)
  Assert.isNil(err)
  assert(records)
  Assert.equal(#records, 1)
end

function T.rejects_a_truncated_declared_record()
  local err = throws(FieldTextureAnimation.ERROR_SIZE, function()
    return u32(2) .. record("sea_on", filled({ { 0, 6 } }))
  end)
  Assert.equal(err.context.source.memberId, 0)

  local tooShort = parseErr("")
  Assert.equal(tooShort.code, FieldTextureAnimation.ERROR_SIZE)
  Assert.equal(tooShort.context.size, 0)
end

function T.rejects_a_missing_terminator()
  local schedule = {}
  for index = 1, 18 do
    schedule[#schedule + 1] = { index % 3, 1 }
  end
  local err = throws(FieldTextureAnimation.ERROR_MISSING_TERMINATOR, function()
    return tableBytes({ record("flower01", schedule) })
  end)
  Assert.equal(err.context.recordIndex, 0)
end

-- A terminator as the first schedule pair leaves no live step: malformed for
-- a compiler that needs a schedule to play.
function T.rejects_an_empty_live_schedule()
  local err = throws(FieldTextureAnimation.ERROR_EMPTY_TIMELINE, function()
    return tableBytes({ record("flower01", filled({})) })
  end)
  Assert.equal(err.context.recordIndex, 0)
end

function T.rejects_an_empty_name()
  local err = throws(FieldTextureAnimation.ERROR_EMPTY_NAME, function()
    return tableBytes({ record("", filled({ { 0, 6 } })) })
  end)
  Assert.equal(err.context.recordIndex, 0)
end

function T.rejects_duplicate_names()
  local err = throws(FieldTextureAnimation.ERROR_DUPLICATE_NAME, function()
    return tableBytes({
      record("sea_on", filled({ { 0, 6 } })),
      record("sea_on", filled({ { 0, 6 } })),
    })
  end)
  Assert.equal(err.context.name, "sea_on")
  Assert.equal(err.context.recordIndex, 1)
end

function T.parses_multiple_records_and_fixed_string_names()
  local bytes = tableBytes({
    record("sea_on", filled({ { 0, 6 } })),
    record("abcdefghijklmnop", filled({ { 1, 12 } })),
    record("dsea_on", filled({ { 1, 12 } })),
  })
  local records, err = FieldTextureAnimation.parse(bytes, SOURCE)
  Assert.isNil(err)
  assert(records)
  Assert.equal(#records, 3)
  Assert.equal(records[1].name, "sea_on")
  Assert.equal(records[2].name, "abcdefghijklmnop")
  Assert.equal(records[3].name, "dsea_on")
  Assert.equal(records[1].index, 0)
  Assert.equal(records[2].index, 1)
  Assert.equal(records[3].index, 2)
end

return { tests = T }
