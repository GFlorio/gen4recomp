-- Tests for FieldLightProfile: record parsing, validation, and cyclic time
-- selection, plus HgssFieldLighting's light-type -> profile/path mapping.

local Assert = require("tests.support.Assert")
local FieldLightProfile = require("src.data.FieldLightProfile")
local HgssFieldLighting = require("src.data.HgssFieldLighting")

local T = {}

-- Build one record block (CRLF), threshold + 4 light lines + 4 color lines.
local function record(threshold, lightColor, vec)
  local light = string.format("1,%d,%d,%d,%d,%d,%d,", lightColor, lightColor, lightColor, vec, vec, vec)
  local off = "0,0,0,0,0,0,0,"
  return table.concat({
    threshold .. ",",
    light, off, off, off,
    "14,14,16,", "10,10,10,", "14,14,16,", "8,8,11,",
    "",
  }, "\r\n")
end

local function profileText(...)
  return table.concat({ ... }, "\r\n") .. "\r\nEOF\r\n"
end

function T.parses_records_and_channels()
  local p = assert(FieldLightProfile.parse(profileText(record(0, 11, -296), record(7200, 18, 4096))))
  Assert.equal(#p.records, 2)
  local r0 = p.records[1]
  Assert.equal(r0.startHalfSeconds, 0)
  Assert.equal(r0.enabledLightMask, 0x1) -- only light 0 enabled
  Assert.equal(#r0.lights, 4)
  Assert.isTrue(r0.lights[1].enabled)
  Assert.isFalse(r0.lights[2].enabled)
  Assert.equal(r0.lights[1].colorRgb555, 11 + 11 * 32 + 11 * 1024)
  Assert.deepEqual(r0.lights[1].vectorFx12, { -296, -296, -296 })
  Assert.equal(r0.diffuseRgb555, 14 + 14 * 32 + 16 * 1024)
end

function T.selects_record_by_time()
  local p = assert(FieldLightProfile.parse(profileText(record(0, 11, 0), record(21600, 18, 0))))
  -- 21600 half-seconds == noon (43200s). Noon selects the second record.
  Assert.equal(FieldLightProfile.select(p, 43200).startHalfSeconds, 21600)
  -- Just before noon selects the first.
  Assert.equal(FieldLightProfile.select(p, 43198).startHalfSeconds, 0)
end

function T.selection_wraps_before_first_threshold()
  -- Elm's area01 profile starts at 900, not midnight; a pre-threshold time must
  -- carry over the day's final record rather than fail.
  local p = assert(FieldLightProfile.parse(profileText(record(900, 11, 0), record(21600, 18, 0))))
  Assert.equal(FieldLightProfile.select(p, 0).startHalfSeconds, 21600)      -- midnight -> wrap to last
  Assert.equal(FieldLightProfile.select(p, 800).startHalfSeconds, 21600)    -- 400 hs (< 900) -> wrap
  Assert.equal(FieldLightProfile.select(p, 2000).startHalfSeconds, 900)     -- 1000 hs -> first record
end

function T.accepts_lf_line_endings()
  local text = profileText(record(0, 11, 0)):gsub("\r\n", "\n")
  Assert.notNil(FieldLightProfile.parse(text))
end

function T.rejects_bad_column_count()
  local text = "0,\r\n1,1,1,1,1,1,\r\n0,0,0,0,0,0,0,\r\n0,0,0,0,0,0,0,\r\n0,0,0,0,0,0,0,\r\n"
    .. "1,1,1,\r\n1,1,1,\r\n1,1,1,\r\n1,1,1,\r\n\r\nEOF\r\n"
  local ok, err = pcall(FieldLightProfile.parse, text)
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_BAD_RECORD")
end

function T.rejects_non_monotonic_thresholds()
  local ok, err = pcall(FieldLightProfile.parse, profileText(record(7200, 11, 0), record(7200, 11, 0)))
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_BAD_THRESHOLD")
end

function T.rejects_out_of_range_channel()
  local ok, err = pcall(FieldLightProfile.parse, profileText(record(0, 99, 0)))
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_VALUE_OUT_OF_RANGE")
end

function T.rejects_out_of_range_vector()
  local ok, err = pcall(FieldLightProfile.parse, profileText(record(0, 11, 9000)))
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_VALUE_OUT_OF_RANGE")
end

function T.rejects_trailing_data_after_eof()
  local text = profileText(record(0, 11, 0)) .. "1,2,3,\r\n"
  local ok, err = pcall(FieldLightProfile.parse, text)
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_BAD_RECORD")
end

function T.rejects_missing_eof()
  local ok, err = pcall(FieldLightProfile.parse, record(0, 11, 0))
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_BAD_RECORD")
end

function T.maps_light_type_to_profile_and_path()
  Assert.equal(HgssFieldLighting.profileIdForLightType(0), 1)
  Assert.equal(HgssFieldLighting.profileIdForLightType(1), 0)
  Assert.equal(HgssFieldLighting.profileIdForLightType(2), 3)
  Assert.equal(HgssFieldLighting.profileIdForLightType(2, true), 4) -- second-dungeon override
  Assert.equal(HgssFieldLighting.profileIdForLightType(9), 0)      -- unknown -> profile 0
  Assert.equal(HgssFieldLighting.pathForProfile(1), "data/area01light.txt")
  Assert.equal(HgssFieldLighting.resolve(0).sourcePath, "data/area01light.txt")
  Assert.equal(HgssFieldLighting.resolve(1).sourcePath, "data/area00light.txt")
end

return T
