-- Tests for HgssFieldLightProfile: parsing and validation of the HGSS
-- field-light profile text tables (data/areaXXlight.txt). The runtime half of
-- the contract (cyclic time selection over parsed records) lives in
-- libs/assets FieldLightProfile.

local Assert = require("tests.support.Assert")
local HgssFieldLightProfile = require("romdump.src.digest.HgssFieldLightProfile")

local T = {}

-- Build one record block (CRLF), threshold + 4 light lines + 4 color lines.
local function record(threshold, lightColor, vec)
  local light = string.format("1,%d,%d,%d,%d,%d,%d,", lightColor, lightColor, lightColor, vec, vec, vec)
  local off = "0,0,0,0,0,0,0,"
  return table.concat({
    threshold .. ",",
    light,
    off,
    off,
    off,
    "14,14,16,",
    "10,10,10,",
    "14,14,16,",
    "8,8,11,",
    "",
  }, "\r\n")
end

local function profileText(...)
  return table.concat({ ... }, "\r\n") .. "\r\nEOF\r\n"
end

function T.parses_records_and_channels()
  local p = assert(HgssFieldLightProfile.parse(profileText(record(0, 11, -296), record(7200, 18, 4096))))
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
  Assert.equal(p.version, "field-light-v1")
end

function T.accepts_lf_line_endings()
  local text = profileText(record(0, 11, 0)):gsub("\r\n", "\n")
  Assert.notNil(HgssFieldLightProfile.parse(text))
end

function T.rejects_bad_column_count()
  local text = "0,\r\n1,1,1,1,1,1,\r\n0,0,0,0,0,0,0,\r\n0,0,0,0,0,0,0,\r\n0,0,0,0,0,0,0,\r\n"
    .. "1,1,1,\r\n1,1,1,\r\n1,1,1,\r\n1,1,1,\r\n\r\nEOF\r\n"
  local ok, err = pcall(HgssFieldLightProfile.parse, text)
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_BAD_RECORD")
end

function T.rejects_non_monotonic_thresholds()
  local ok, err = pcall(HgssFieldLightProfile.parse, profileText(record(7200, 11, 0), record(7200, 11, 0)))
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_BAD_THRESHOLD")
end

function T.rejects_out_of_range_channel()
  local ok, err = pcall(HgssFieldLightProfile.parse, profileText(record(0, 99, 0)))
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_VALUE_OUT_OF_RANGE")
end

function T.rejects_out_of_range_vector()
  local ok, err = pcall(HgssFieldLightProfile.parse, profileText(record(0, 11, 9000)))
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_VALUE_OUT_OF_RANGE")
end

function T.rejects_trailing_data_after_eof()
  local text = profileText(record(0, 11, 0)) .. "1,2,3,\r\n"
  local ok, err = pcall(HgssFieldLightProfile.parse, text)
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_BAD_RECORD")
end

function T.rejects_missing_eof()
  local ok, err = pcall(HgssFieldLightProfile.parse, record(0, 11, 0))
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_BAD_RECORD")
end

function T.rejects_short_profile()
  local ok, err = pcall(HgssFieldLightProfile.parse, profileText(record(0, 11, 0), "1,1,1,"))
  Assert.isFalse(ok)
  Assert.equal(err.code, "FIELD_LIGHT_BAD_RECORD")
end

return { metadata = { layer = "unit" }, tests = T }
