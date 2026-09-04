-- Runtime time-of-day selection over normalized field-light profile records.
-- The records are generated from HGSS source text tables; parsing and
-- validation of that source grammar belongs to romdump's
-- HgssFieldLightProfile, and the runtime consumes only the parsed records.
-- Selection is cyclic over the day: before the first threshold the last
-- record carries over (e.g. area01light.txt starts at threshold 900, not
-- midnight), so there is no "first record must cover midnight" requirement.
-- Pure domain module: no love, no source text knowledge.

local FieldLightProfile = {}

local SECONDS_PER_DAY = 86400
local DEFAULT_TIME_SECONDS = 43200 -- noon

-- Select the active record for a wall-clock second-of-day, cyclically: the last
-- record whose threshold <= now, or (before the first threshold) the final
-- record carried over from the previous day.
---@param profile { records: table[] }
---@param secondsSinceMidnight number
---@return table<string, unknown> record
function FieldLightProfile.select(profile, secondsSinceMidnight)
  assert(profile and profile.records and #profile.records > 0, "profile has no records")
  local halfSeconds = math.floor((secondsSinceMidnight % SECONDS_PER_DAY) / 2)
  local chosen = profile.records[#profile.records]
  for _, rec in ipairs(profile.records) do
    if rec.startHalfSeconds <= halfSeconds then
      chosen = rec
    else
      break
    end
  end
  return chosen
end

FieldLightProfile.DEFAULT_TIME_SECONDS = DEFAULT_TIME_SECONDS

return FieldLightProfile
