local Assert = require("tests.support.Assert")
local Errors = require("src.import.Errors")
local MapMatrix = require("src.data.MapMatrix")

local T = {}

local function u8(v) return string.char(v % 256) end
local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end

-- Assemble a map-matrix member. Header/altitude arrays are only
-- emitted when their section flag is set.
local function build(spec)
  local n = spec.width * spec.height
  local name = spec.name or ""
  local parts = {
    u8(spec.width), u8(spec.height),
    u8(spec.hasHeaders and 1 or 0),
    u8(spec.hasAltitudes and 1 or 0),
    u8(#name), name,
  }
  if spec.hasHeaders then
    for i = 1, n do parts[#parts + 1] = u16(spec.headers[i]) end
  end
  if spec.hasAltitudes then
    for i = 1, n do parts[#parts + 1] = u8(spec.altitudes[i]) end
  end
  for i = 1, n do parts[#parts + 1] = u16(spec.modelIds[i]) end
  return table.concat(parts)
end

-- 2x2 with distinct values in every section, laid out row-major.
local function sample(hasHeaders, hasAltitudes)
  return build({
    width = 2, height = 2, name = "MAP",
    hasHeaders = hasHeaders, hasAltitudes = hasAltitudes,
    headers = { 10, 11, 12, 13 },
    altitudes = { 1, 2, 3, 4 },
    modelIds = { 20, 21, 22, 23 },
  })
end

local function decodeOk(data, default)
  local m, err = MapMatrix.decode(data, default)
  Assert.notNil(m, "expected decode to succeed: " .. tostring(err))
  return m
end

function T.decodes_both_sections_present()
  local m = decodeOk(sample(true, true))
  Assert.equal(m.width, 2)
  Assert.equal(m.height, 2)
  Assert.equal(m.name, "MAP")
  Assert.isTrue(m.hasHeaders)
  Assert.isTrue(m.hasAltitudes)
  Assert.equal(m:mapHeaderIdAt(0, 0), 10)
  Assert.equal(m:mapHeaderIdAt(1, 0), 11)
  Assert.equal(m:mapHeaderIdAt(0, 1), 12)
  Assert.equal(m:mapHeaderIdAt(1, 1), 13)
  Assert.equal(m:altitudeAt(1, 1), 4)
  Assert.equal(m:modelIdAt(0, 0), 20)
  Assert.equal(m:modelIdAt(1, 1), 23)
end

function T.headers_absent_fill_with_default()
  local m = decodeOk(sample(false, true), 7)
  Assert.isFalse(m.hasHeaders)
  Assert.equal(m:mapHeaderIdAt(0, 0), 7)
  Assert.equal(m:mapHeaderIdAt(1, 1), 7)
  -- altitudes still decoded, model ids follow immediately after
  Assert.equal(m:altitudeAt(0, 1), 3)
  Assert.equal(m:modelIdAt(1, 0), 21)
end

function T.altitudes_absent_fill_with_zero()
  local m = decodeOk(sample(true, false))
  Assert.isFalse(m.hasAltitudes)
  Assert.equal(m:altitudeAt(0, 0), 0)
  Assert.equal(m:altitudeAt(1, 1), 0)
  Assert.equal(m:mapHeaderIdAt(1, 0), 11)
  Assert.equal(m:modelIdAt(0, 1), 22)
end

function T.both_sections_absent()
  local m = decodeOk(sample(false, false), 5)
  Assert.equal(m:mapHeaderIdAt(1, 1), 5)
  Assert.equal(m:altitudeAt(1, 1), 0)
  Assert.equal(m:modelIdAt(1, 1), 23)
end

function T.index_is_zero_based_row_major()
  local m = decodeOk(sample(true, true))
  Assert.equal(m:index(0, 0), 0)
  Assert.equal(m:index(1, 0), 1)
  Assert.equal(m:index(0, 1), 2)
  Assert.equal(m:index(1, 1), 3)
end

function T.coordinate_accessors_reject_out_of_range()
  local m = decodeOk(sample(true, true))
  Assert.throws(function() m:index(2, 0) end)
  Assert.throws(function() m:index(0, 2) end)
  Assert.throws(function() m:index(-1, 0) end)
  Assert.throws(function() m:mapHeaderIdAt(0, 2) end)
end

function T.rejects_zero_dimension()
  local m, err = MapMatrix.decode(u8(0) .. u8(1) .. u8(0) .. u8(0) .. u8(0))
  Assert.isNil(m)
  Assert.equal(err.code, "MAP_MATRIX_EMPTY")
end

-- 40x20 = 800 cells, one past the decompilation's 799-cell capacity.
function T.rejects_cell_count_over_limit()
  local m, err = MapMatrix.decode(u8(40) .. u8(20) .. u8(0) .. u8(0) .. u8(0))
  Assert.isNil(m)
  Assert.equal(err.code, "MAP_MATRIX_TOO_LARGE")
end

function T.rejects_name_over_limit()
  local m, err = MapMatrix.decode(u8(1) .. u8(1) .. u8(0) .. u8(0) .. u8(17))
  Assert.isNil(m)
  Assert.equal(err.code, "MAP_MATRIX_NAME_TOO_LONG")
end

function T.rejects_bad_section_flag()
  local m, err = MapMatrix.decode(u8(1) .. u8(1) .. u8(2) .. u8(0) .. u8(0))
  Assert.isNil(m)
  Assert.equal(err.code, "MAP_MATRIX_BAD_FLAG")
end

function T.rejects_truncated_model_section()
  local full = sample(true, true)
  local m, err = MapMatrix.decode(full:sub(1, #full - 1))
  Assert.isNil(m)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, "READ_OUT_OF_BOUNDS")
end

return T
