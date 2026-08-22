-- Pure Professor Oak greeting policy. Its boundaries are the source opening
-- message ranges and intentionally do not share the field day/night policy.

local OakGreetingPolicy = {}

local RANGES = {
  { first = 0, last = 3, band = "midnight" },
  { first = 4, last = 10, band = "morning" },
  { first = 11, last = 15, band = "day" },
  { first = 16, last = 18, band = "evening" },
  { first = 19, last = 23, band = "night" },
}

---@param hour integer
---@param minute integer
---@return "midnight"|"morning"|"day"|"evening"|"night"
function OakGreetingPolicy.bandAt(hour, minute)
  assert(type(hour) == "number" and hour % 1 == 0 and hour >= 0 and hour <= 23, "Oak hour must be 0..23")
  assert(type(minute) == "number" and minute % 1 == 0 and minute >= 0 and minute <= 59, "Oak minute must be 0..59")
  for _, range in ipairs(RANGES) do
    if hour >= range.first and hour <= range.last then
      return range.band
    end
  end
  error("Oak greeting range is incomplete", 0)
end

---@param civilTime table
---@return string
function OakGreetingPolicy.messageKey(civilTime)
  assert(type(civilTime) == "table", "Oak greeting requires civil time")
  return "greeting." .. OakGreetingPolicy.bandAt(civilTime.hour, civilTime.minute)
end

return OakGreetingPolicy
