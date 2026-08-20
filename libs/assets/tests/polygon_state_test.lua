-- PolygonState: the one polygon draw-state schema shared by the compiler
-- emission, the serialized-artifact validator, and the runtime backend
-- records. FIELDS is the single list; requirePresent and validate are the
-- strict checks the asset boundary (ModelAsset) converts into its own error
-- contract, and copy builds the backend record shape. Scene-form and model
-- batch records always carry the full field set (the compilers emit it), so
-- there is no defaulting path.

local Assert = require("tests.support.Assert")
local PolygonState = require("libs.assets.src.PolygonState")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isTrue(not ok, "expected raise, got success")
  Assert.equal(code, err.code, "error code")
end

local function validRecord()
  return {
    cullMode = "back",
    polygonMode = "modulation",
    polygonId = 0,
    translucentDepthWrite = false,
    depthEqual = false,
    polygonAlpha = 31,
    lightMask = 5,
    fogEnabled = false,
  }
end

function T.fields_is_the_full_shared_draw_state_list()
  Assert.deepEqual(PolygonState.FIELDS, {
    "cullMode",
    "polygonMode",
    "polygonId",
    "translucentDepthWrite",
    "depthEqual",
    "polygonAlpha",
    "lightMask",
    "fogEnabled",
  })
end

function T.require_present_accepts_a_complete_record()
  PolygonState.requirePresent(validRecord(), "batch")
end

-- The presence check is uniform over FIELDS; one representative missing
-- field plus the full-list sweep prove the loop, not each string.
function T.require_present_rejects_a_missing_field()
  for _, field in ipairs(PolygonState.FIELDS) do
    local record = validRecord()
    record[field] = nil
    throwsCode(PolygonState.ERROR_MISSING_FIELD, function()
      PolygonState.requirePresent(record, "batch")
    end)
  end
end

function T.validate_accepts_a_valid_record()
  PolygonState.validate(validRecord(), "batch")
end

function T.validate_rejects_translucent_depth_write_true()
  local record = validRecord()
  record.translucentDepthWrite = true
  throwsCode(PolygonState.ERROR_TRANSLUCENT_DEPTH_WRITE_UNSUPPORTED, function()
    PolygonState.validate(record, "batch")
  end)
end

-- Range and vocabulary branches are distinct checks over distinct fields,
-- so each invalid value is one case in the sweep.
function T.validate_rejects_out_of_range_values()
  local cases = {
    { field = "polygonId", value = 64 },
    { field = "polygonId", value = -1 },
    { field = "polygonId", value = 0.5 },
    { field = "polygonAlpha", value = 32 },
    { field = "polygonAlpha", value = -1 },
    { field = "lightMask", value = 16 },
    { field = "lightMask", value = -1 },
    { field = "cullMode", value = "all" },
    { field = "cullMode", value = "sideways" },
    { field = "polygonMode", value = "lit" },
    { field = "translucentDepthWrite", value = 1 },
    { field = "depthEqual", value = "false" },
    { field = "fogEnabled", value = "false" },
  }
  for _, case in ipairs(cases) do
    local record = validRecord()
    record[case.field] = case.value
    throwsCode(PolygonState.ERROR_INVALID, function()
      PolygonState.validate(record, "batch")
    end)
  end
end

-- The HGSS field render-state corpus census found zero materials of any
-- model class (map, building, field actor) resolving POLYGON_ATTR
-- depth-equal (see tests/rom/specular_shininess_census_test.lua). The
-- renderer must not present host `lequal` as an implemented DS depth-equal
-- behavior, so a batch that claims depthEqual fails compilation here, at the
-- one shared draw-state validator, rather than silently reaching
-- MapRenderer.
function T.validate_rejects_depth_equal_true()
  local record = validRecord()
  record.depthEqual = true
  throwsCode(PolygonState.ERROR_DEPTH_EQUAL_UNSUPPORTED, function()
    PolygonState.validate(record, "batch")
  end)
end

function T.copy_carries_exactly_the_shared_fields()
  local record = validRecord()
  record.farClipEnabled = true
  record.oneDotEnabled = false
  local copy = PolygonState.copy(record)
  Assert.deepEqual(copy, validRecord())
  Assert.isTrue(copy ~= record, "copy must not alias the source record")
end

return { tests = T }
