-- Parser tests for the HGSS field texture-animation table: the member-0
-- contents of `data/fldtanime.narc` in pret/pokeheartgold, a little-endian
-- u32 record count followed by fixed 52-byte records of a NUL-padded 16-byte
-- name and an 18-pair schedule. The strict rules -- exact total size,
-- non-empty unique names, one { 0xFF, 0xFF } sentinel within the 18 pairs
-- with sentinel-only data after it, and positive live durations -- pin the
-- public boundary, which returns `nil, err` for project errors.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldTextureAnimation = require("romdump.src.digest.FieldTextureAnimation")

local T = {}

local SENTINEL = { 0xFF, 0xFF }
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

-- Pads a live schedule with sentinel pairs up to the 18-pair record width.
local function filled(schedule)
  local out = {}
  for _, entry in ipairs(schedule) do
    out[#out + 1] = entry
  end
  while #out < 18 do
    out[#out + 1] = SENTINEL
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

function T.parses_one_valid_record_with_exact_zero_based_timeline()
  local bytes = tableBytes({
    record(
      "flower01",
      filled({
        { 0, 18 },
        { 1, 18 },
        { 0, 18 },
        { 2, 18 },
        SENTINEL,
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

function T.parses_multiple_records_and_fixed_string_names()
  local bytes = tableBytes({
    record("sea_on", filled({ { 0, 6 }, SENTINEL })),
    record("abcdefghijklmnop", filled({ SENTINEL })),
    record("dsea_on", filled({ { 1, 12 }, SENTINEL })),
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

-- An empty table is valid generated input (`recordCount = 0`, total size 4),
-- even though the retail archive census expects nine records.
function T.parses_a_zero_record_table_as_valid()
  local records, err = FieldTextureAnimation.parse(u32(0), SOURCE)
  Assert.isNil(err)
  assert(records)
  Assert.deepEqual(records, {})
end

function T.rejects_bad_total_size_and_trailing_bytes()
  local valid = tableBytes({ record("sea_on", filled({ SENTINEL })) })
  local err = parseErr(valid .. "\0")
  Assert.equal(err.code, "FIELD_TEX_ANIM_SIZE_MISMATCH")
  Assert.equal(err.context.source.memberId, 0)

  local truncated = u32(2) .. record("sea_on", filled({ SENTINEL }))
  Assert.equal(parseErr(truncated).code, "FIELD_TEX_ANIM_SIZE_MISMATCH")

  local tooShort = parseErr("")
  Assert.equal(tooShort.code, "FIELD_TEX_ANIM_SIZE_MISMATCH")
  Assert.equal(tooShort.context.size, 0)
end

function T.rejects_an_empty_name()
  local err = parseErr(tableBytes({ record("", filled({ SENTINEL })) }))
  Assert.equal(err.code, "FIELD_TEX_ANIM_EMPTY_NAME")
  Assert.equal(err.context.recordIndex, 0)
end

function T.rejects_duplicate_names()
  local err = parseErr(tableBytes({
    record("sea_on", filled({ SENTINEL })),
    record("sea_on", filled({ SENTINEL })),
  }))
  Assert.equal(err.code, "FIELD_TEX_ANIM_DUPLICATE_NAME")
  Assert.equal(err.context.name, "sea_on")
  Assert.equal(err.context.recordIndex, 1)
end

function T.rejects_a_missing_sentinel()
  local schedule = {}
  for index = 1, 18 do
    schedule[#schedule + 1] = { index % 3, 1 }
  end
  local err = parseErr(tableBytes({ record("flower01", schedule) }))
  Assert.equal(err.code, "FIELD_TEX_ANIM_MISSING_SENTINEL")
  Assert.equal(err.context.recordIndex, 0)
end

function T.rejects_a_half_sentinel()
  local err = parseErr(tableBytes({ record("flower01", filled({ { 0xFF, 3 } })) }))
  Assert.equal(err.code, "FIELD_TEX_ANIM_BAD_SENTINEL")
  Assert.equal(err.context.recordIndex, 0)
  Assert.equal(err.context.pairIndex, 0)
end

function T.rejects_non_sentinel_data_after_the_sentinel()
  local err = parseErr(tableBytes({ record("flower01", filled({ SENTINEL, { 0x01, 0x02 } })) }))
  Assert.equal(err.code, "FIELD_TEX_ANIM_BAD_SENTINEL")
  Assert.equal(err.context.recordIndex, 0)
  Assert.equal(err.context.pairIndex, 1)
end

function T.rejects_a_zero_live_duration()
  local err = parseErr(tableBytes({ record("flower01", filled({ { 0, 0 } })) }))
  Assert.equal(err.code, "FIELD_TEX_ANIM_ZERO_DURATION")
  Assert.equal(err.context.recordIndex, 0)
  Assert.equal(err.context.pairIndex, 0)
end

return { tests = T }
