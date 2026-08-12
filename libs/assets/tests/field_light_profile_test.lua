-- Tests for the runtime half of FieldLightProfile: cyclic time-of-day
-- selection over normalized records. Parsing of the HGSS source text lives
-- with HgssFieldLightProfile under romdump.

local Assert = require("tests.support.Assert")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")

local T = {}

-- One record with the given half-second threshold.
local function record(threshold)
  return {
    startHalfSeconds = threshold,
    enabledLightMask = 1,
    lights = {},
    diffuseRgb555 = 0,
    ambientRgb555 = 0,
    specularRgb555 = 0,
    emissionRgb555 = 0,
  }
end

function T.selects_record_by_time()
  local p = { records = { record(0), record(21600) } }
  -- 21600 half-seconds == noon (43200s). Noon selects the second record.
  Assert.equal(FieldLightProfile.select(p, 43200).startHalfSeconds, 21600)
  -- Just before noon selects the first.
  Assert.equal(FieldLightProfile.select(p, 43198).startHalfSeconds, 0)
end

function T.selection_wraps_before_first_threshold()
  -- Elm's area01 profile starts at 900, not midnight; a pre-threshold time must
  -- carry over the day's final record rather than fail.
  local p = { records = { record(900), record(21600) } }
  Assert.equal(FieldLightProfile.select(p, 0).startHalfSeconds, 21600) -- midnight -> wrap to last
  Assert.equal(FieldLightProfile.select(p, 800).startHalfSeconds, 21600) -- 400 hs (< 900) -> wrap
  Assert.equal(FieldLightProfile.select(p, 2000).startHalfSeconds, 900) -- 1000 hs -> first record
end

function T.default_time_is_noon()
  Assert.equal(FieldLightProfile.DEFAULT_TIME_SECONDS, 43200)
end

function T.empty_profile_is_fatal()
  Assert.throws(function()
    FieldLightProfile.select({ records = {} }, 0)
  end)
end

return T
