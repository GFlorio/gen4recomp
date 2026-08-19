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

local function validateCatalog(catalog)
  if type(catalog) ~= "table" then
    fail("catalog must be a table", {})
  end
  if catalog.schema ~= "g4-field-weather-v1" then
    fail("catalog schema must be g4-field-weather-v1", { schema = catalog.schema })
  end
  if type(catalog.presets) ~= "table" then
    fail("catalog presets must be a table", {})
  end
  local count = 0
  for _ in pairs(catalog.presets) do
    count = count + 1
  end
  if count ~= 14 then
    fail("catalog must have exactly 14 presets (0..13)", { count = count })
  end
  for id = 0, 13 do
    local preset = catalog.presets[id]
    if type(preset) ~= "table" then
      fail("preset " .. id .. " must be a table", { id = id })
    end
    if type(preset.enabled) ~= "boolean" then
      fail("preset " .. id .. " enabled must be a boolean", { id = id })
    end
    for _, field in ipairs({ "color", "offset", "slope", "alpha" }) do
      local v = preset[field]
      if type(v) ~= "number" or v ~= math.floor(v) then
        fail("preset " .. id .. " " .. field .. " must be an integer", { id = id, field = field })
      end
    end
    if type(preset.table) ~= "table" or #preset.table ~= 32 then
      fail("preset " .. id .. " table must have exactly 32 entries", { id = id })
    end
  end
  if type(catalog.rules) ~= "table" then
    fail("catalog rules must be a table", {})
  end
  for i, rule in ipairs(catalog.rules) do
    if type(rule) ~= "table" then
      fail("rule " .. i .. " must be a table", { index = i })
    end
    local kind = rule.kind
    if kind ~= "calendar_map_override" and kind ~= "map_var_equals" and kind ~= "weather_flag_override" then
      fail("rule " .. i .. " has unknown kind " .. tostring(kind), { index = i, kind = kind })
    end
    if
      type(rule.weatherId) ~= "number"
      or rule.weatherId ~= math.floor(rule.weatherId)
      or rule.weatherId < 0
      or rule.weatherId > 13
    then
      fail("rule " .. i .. " weatherId must be 0..13", { index = i })
    end
    if catalog.presets[rule.weatherId] == nil then
      fail("rule " .. i .. " target weatherId has no preset", { index = i, weatherId = rule.weatherId })
    end
    if kind == "calendar_map_override" then
      if type(rule.mapId) ~= "number" then
        fail("rule " .. i .. " mapId required", { index = i })
      end
      if rule.requireNoPenalty ~= true then
        fail("rule " .. i .. " requireNoPenalty must be true", { index = i })
      end
      if type(rule.dates) ~= "table" or #rule.dates == 0 then
        fail("rule " .. i .. " dates must be a non-empty table", { index = i })
      end
      for j, entry in ipairs(rule.dates) do
        if type(entry) ~= "table" or type(entry.month) ~= "number" or type(entry.day) ~= "number" then
          fail("rule " .. i .. " date " .. j .. " must have month and day", { index = i, entry = j })
        end
      end
    elseif kind == "map_var_equals" then
      if type(rule.mapId) ~= "number" then
        fail("rule " .. i .. " mapId required", { index = i })
      end
      if type(rule.varId) ~= "number" then
        fail("rule " .. i .. " varId required", { index = i })
      end
      if type(rule.value) ~= "number" then
        fail("rule " .. i .. " value required", { index = i })
      end
    elseif kind == "weather_flag_override" then
      if type(rule.fromWeatherId) ~= "number" then
        fail("rule " .. i .. " fromWeatherId required", { index = i })
      end
      if catalog.presets[rule.fromWeatherId] == nil then
        fail("rule " .. i .. " fromWeatherId has no preset", { index = i, fromWeatherId = rule.fromWeatherId })
      end
      if type(rule.flagId) ~= "number" then
        fail("rule " .. i .. " flagId required", { index = i })
      end
    end
  end
end

-- Resolve the effective weather ID: fold catalog.rules in order starting
-- from baseWeatherId, rewriting the current value where a rule matches.
-- inputs: { mapId, baseWeatherId, eventState, date={month,day}, hasPenalty }
function FieldWeatherResolver.resolve(catalog, inputs)
  validateCatalog(catalog)
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
