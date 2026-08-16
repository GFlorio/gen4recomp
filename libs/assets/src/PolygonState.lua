-- The one polygon draw-state schema shared by the compiler emission, the
-- serialized-artifact validator, and the runtime backend records: the
-- static batch compiler (ModelAssetCompiler) and the dynamic segment path
-- (MapAssetCompiler) write these fields on both batch kinds,
-- ModelAsset.validate gates them at the artifact boundary, and the runtime
-- backend records (ModelDefinition, ModelInstance) copy and consume them.
-- The static batch extras (farClipEnabled, oneDotEnabled) are authoring
-- metadata the runtime does not consume, so they stay outside the shared
-- schema. fogEnabled is included: the map shader's fog pass reads it per
-- draw item, the same way lightMask/cullMode do. No draw-state class
-- hierarchy. Pure domain module.

local Errors = require("libs.errors.src.Errors")

local PolygonState = {}

PolygonState.ERROR_MISSING_FIELD = "POLYGON_STATE_MISSING_FIELD"
PolygonState.ERROR_INVALID = "POLYGON_STATE_INVALID"
PolygonState.ERROR_DEPTH_EQUAL_UNSUPPORTED = "POLYGON_STATE_DEPTH_EQUAL_UNSUPPORTED"

-- The polygon draw-state fields every serialized batch record carries (the
-- shape DsPolygonAttr.decode normalizes the DS POLYGON_ATTR word into).
PolygonState.FIELDS = {
  "cullMode",
  "polygonMode",
  "polygonId",
  "translucentDepthWrite",
  "depthEqual",
  "polygonAlpha",
  "lightMask",
  "fogEnabled",
}

-- The emitted cull-mode vocabulary: a polygon rendering neither surface is
-- skipped by the compiler, so "all" never reaches a serialized record.
local CULL_MODES = { back = true, front = true, none = true }

-- The four DS polygon modes (DsPolygonAttr.POLYGON_MODES); the dynamic path
-- emits only modulation/decal, the static path can carry toon/shadow.
local POLYGON_MODES = { modulation = true, decal = true, toon = true, shadow = true }

local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

-- Require every shared draw-state field on a batch record. Raises
-- POLYGON_STATE_MISSING_FIELD carrying the field and the caller's record
-- label (as `where`); each consumer boundary converts to its own error
-- contract.
function PolygonState.requirePresent(record, context)
  for _, field in ipairs(PolygonState.FIELDS) do
    if record[field] == nil then
      Errors.raise(
        PolygonState.ERROR_MISSING_FIELD,
        "batch is missing the " .. field .. " polygon draw state",
        { field = field, where = context }
      )
    end
  end
end

-- Strict range and vocabulary checks over the shared field set (presence
-- included). Raises POLYGON_STATE_INVALID.
function PolygonState.validate(record, context)
  PolygonState.requirePresent(record, context)
  local function invalid(what)
    Errors.raise(PolygonState.ERROR_INVALID, "batch " .. what, { where = context })
  end
  if not CULL_MODES[record.cullMode] then
    invalid("cullMode must be back, front, or none")
  end
  if not POLYGON_MODES[record.polygonMode] then
    invalid("polygonMode must be modulation, decal, toon, or shadow")
  end
  if not (isInteger(record.polygonId) and record.polygonId >= 0 and record.polygonId <= 63) then
    invalid("polygonId must be an integer in 0..63")
  end
  if not (isInteger(record.polygonAlpha) and record.polygonAlpha >= 0 and record.polygonAlpha <= 31) then
    invalid("polygonAlpha must be an integer in 0..31")
  end
  if not (isInteger(record.lightMask) and record.lightMask >= 0 and record.lightMask <= 15) then
    invalid("lightMask must be an integer in 0..15")
  end
  if type(record.translucentDepthWrite) ~= "boolean" then
    invalid("translucentDepthWrite must be a boolean")
  end
  if type(record.depthEqual) ~= "boolean" then
    invalid("depthEqual must be a boolean")
  end
  if record.depthEqual then
    -- The HGSS field render-state census (map, building, and both field
    -- actor archives) never resolves POLYGON_ATTR depth-equal to true; see
    -- tests/rom/specular_shininess_census_test.lua. Rather than keep
    -- presenting the host `lequal` depth mode as an implemented DS
    -- depth-equal behavior, fail compilation loudly the moment a batch
    -- claims it, mirroring MAP_COMPILE_UNSUPPORTED_POLYGON_MODE's precedent
    -- for other corpus-provable-absent states.
    Errors.raise(
      PolygonState.ERROR_DEPTH_EQUAL_UNSUPPORTED,
      "batch depthEqual = true is not supported: the HGSS field corpus never exercises DS depth-equal",
      { where = context }
    )
  end
  if type(record.fogEnabled) ~= "boolean" then
    invalid("fogEnabled must be a boolean")
  end
end

-- Copy the shared field set into a new record: the runtime backend record
-- shape ModelDefinition and ModelInstance consume.
function PolygonState.copy(record)
  local out = {}
  for _, field in ipairs(PolygonState.FIELDS) do
    out[field] = record[field]
  end
  return out
end

return PolygonState
