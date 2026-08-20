-- Pure resolver for effective field weather. Consumes the normalized
-- generated weather catalog (presets 0..13 plus ordered rule descriptors)
-- plus runtime inputs (mapId, baseWeatherId, eventState, date,
-- hasPenalty). No LÖVE dependency and no romdump imports. The rules are
-- applied in serialized order as a fold over the current weather: each
-- rule may rewrite the current value or leave it untouched. Numeric
-- rule IDs (map, var, flag, weather) are treated opaquely -- no literals
-- appear here; only generic kind semantics.

local Errors = require("libs.errors.src.Errors")

local FieldWeatherResolver = {}

local CATALOG_INVALID = "FIELD_WEATHER_CATALOG_INVALID"

local function fail(message, context)
  Errors.raise(CATALOG_INVALID, message, context or {})
end

-- Resolve the effective weather ID from an already-validated catalog: fold
-- catalog.rules in order starting from baseWeatherId, rewriting the current
-- value where a rule matches.
-- inputs: { mapId, baseWeatherId, eventState, date={month,day}, hasPenalty }
function FieldWeatherResolver.resolve(catalog, inputs)
  if type(inputs) ~= "table" then
    fail("resolve inputs must be a table", {})
  end
  local mapId = inputs.mapId
  local baseWeatherId = inputs.baseWeatherId
  if type(baseWeatherId) ~= "number" or baseWeatherId ~= math.floor(baseWeatherId) then
    fail("baseWeatherId must be an integer", { baseWeatherId = baseWeatherId })
  end
  if catalog.presets[baseWeatherId] == nil then
    fail("baseWeatherId " .. baseWeatherId .. " has no preset", { baseWeatherId = baseWeatherId })
  end
  local eventState = inputs.eventState
  if not eventState or type(eventState.isFlagSet) ~= "function" or type(eventState.getVar) ~= "function" then
    fail("eventState must expose isFlagSet and getVar", {})
  end
  local date = inputs.date
  if type(date) ~= "table" or type(date.month) ~= "number" or type(date.day) ~= "number" then
    fail("date must be { month, day }", {})
  end
  local hasPenalty = inputs.hasPenalty
  if type(hasPenalty) ~= "boolean" then
    fail("hasPenalty must be a boolean", {})
  end

  local current = baseWeatherId
  for i = 1, #catalog.rules do
    local rule = catalog.rules[i]
    if rule.kind == "calendar_map_override" then
      if mapId == rule.mapId and hasPenalty == false then
        for j = 1, #rule.dates do
          local entry = rule.dates[j]
          if entry.month == date.month and entry.day == date.day then
            current = rule.weatherId
            break
          end
        end
      end
    elseif rule.kind == "map_var_equals" then
      if mapId == rule.mapId and eventState:getVar(rule.varId) == rule.value then
        current = rule.weatherId
      end
    elseif rule.kind == "weather_flag_override" then
      if current == rule.fromWeatherId and eventState:isFlagSet(rule.flagId) then
        current = rule.weatherId
      end
    end
  end
  if catalog.presets[current] == nil then
    fail("effective weatherId " .. current .. " has no preset", { weatherId = current })
  end
  return current
end

return FieldWeatherResolver
