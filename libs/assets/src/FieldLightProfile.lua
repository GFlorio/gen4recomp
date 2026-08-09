-- Parser and time selector for an HGSS field-light profile text table (e.g.
-- data/area00light.txt). Each record is a time threshold, four directional light
-- slots (enable + BGR555 color + fx12 vector), and four material colors
-- (diffuse/ambient/specular/emission). The field engine picks the active record
-- from the time of day; DsLighting later turns it into per-vertex color. This
-- module is pure: it takes the file text (LF or CRLF) and returns normalized
-- integer records; hashing/IO stays with the caller.
--
-- Selection is cyclic over the day: before the first threshold the last record
-- carries over (e.g. area01light.txt starts at threshold 900, not midnight), so
-- there is no "first record must cover midnight" requirement. Source: the field
-- light tables and loader in pret/pokeheartgold.

local Errors = require("libs.rom.src.Errors")

local FieldLightProfile = {}

FieldLightProfile.VERSION = "field-light-v1"

local SECONDS_PER_DAY = 86400
local DEFAULT_TIME_SECONDS = 43200 -- noon
local LIGHT_SLOTS = 4
local LINES_PER_RECORD = 1 + LIGHT_SLOTS + 4 -- threshold, 4 lights, 4 colors

-- Collect the signed integers on a line (the trailing comma is ignored).
local function numbers(line)
  local out = {}
  for n in line:gmatch("-?%d+") do
    out[#out + 1] = tonumber(n)
  end
  return out
end

local function checkColumns(nums, expected, lineNo, context)
  if #nums ~= expected then
    Errors.raise(
      "FIELD_LIGHT_BAD_RECORD",
      string.format("line %d has %d columns, expected %d", lineNo, #nums, expected),
      { line = lineNo, source = context }
    )
  end
end

local function checkRange(value, lo, hi, code, lineNo, context)
  if value < lo or value > hi then
    Errors.raise(
      code,
      string.format("line %d value %d out of range [%d,%d]", lineNo, value, lo, hi),
      { line = lineNo, value = value, source = context }
    )
  end
end

local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

-- Parse one light slot line "enabled,r,g,b,x,y,z,".
local function parseLight(nums, lineNo, context)
  local enabled, r, g, b, x, y, z = nums[1], nums[2], nums[3], nums[4], nums[5], nums[6], nums[7]
  checkRange(enabled, 0, 1, "FIELD_LIGHT_VALUE_OUT_OF_RANGE", lineNo, context)
  for _, c in ipairs({ r, g, b }) do
    checkRange(c, 0, 31, "FIELD_LIGHT_VALUE_OUT_OF_RANGE", lineNo, context)
  end
  for _, v in ipairs({ x, y, z }) do
    checkRange(v, -4096, 4096, "FIELD_LIGHT_VALUE_OUT_OF_RANGE", lineNo, context)
  end
  return {
    enabled = enabled == 1,
    colorRgb555 = rgb555(r, g, b),
    vectorFx12 = { x, y, z },
  }
end

-- Parse one material color line "r,g,b,".
local function parseColor(nums, lineNo, context)
  for _, c in ipairs(nums) do
    checkRange(c, 0, 31, "FIELD_LIGHT_VALUE_OUT_OF_RANGE", lineNo, context)
  end
  return rgb555(nums[1], nums[2], nums[3])
end

-- Split text into data lines (CRLF/LF tolerant), stopping at the EOF marker and
-- rejecting any non-blank content after it. Blank lines separate records and are
-- dropped. Returns { { text, lineNo }, ... }.
local function dataLines(text, context)
  local lines = {}
  local lineNo = 0
  local seenEof = false
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    lineNo = lineNo + 1
    local line = raw:gsub("\r$", "")
    local trimmed = line:gsub("%s+", "")
    if seenEof then
      if trimmed ~= "" then
        Errors.raise(
          "FIELD_LIGHT_BAD_RECORD",
          "non-blank data after EOF at line " .. lineNo,
          { line = lineNo, source = context }
        )
      end
    elseif trimmed == "EOF" then
      seenEof = true
    elseif trimmed ~= "" then
      lines[#lines + 1] = { text = line, lineNo = lineNo }
    end
  end
  if not seenEof then
    Errors.raise("FIELD_LIGHT_BAD_RECORD", "profile text has no EOF marker", { source = context })
  end
  return lines
end

-- Parse profile text into { version, records = { record, ... } }.
function FieldLightProfile.parse(text, context)
  assert(type(text) == "string", "FieldLightProfile.parse requires a string")
  local lines = dataLines(text, context)
  if #lines == 0 or #lines % LINES_PER_RECORD ~= 0 then
    Errors.raise(
      "FIELD_LIGHT_BAD_RECORD",
      string.format("profile has %d data lines, not a multiple of %d", #lines, LINES_PER_RECORD),
      { source = context }
    )
  end

  local records = {}
  local lastThreshold
  for base = 1, #lines, LINES_PER_RECORD do
    local thresholdLine = lines[base]
    local tnums = numbers(thresholdLine.text)
    checkColumns(tnums, 1, thresholdLine.lineNo, context)
    local startHalfSeconds = tnums[1]
    checkRange(startHalfSeconds, 0, SECONDS_PER_DAY / 2, "FIELD_LIGHT_BAD_THRESHOLD", thresholdLine.lineNo, context)
    if lastThreshold and startHalfSeconds <= lastThreshold then
      Errors.raise(
        "FIELD_LIGHT_BAD_THRESHOLD",
        string.format("threshold %d at line %d is not strictly increasing", startHalfSeconds, thresholdLine.lineNo),
        { line = thresholdLine.lineNo, source = context }
      )
    end
    lastThreshold = startHalfSeconds

    local lights, enabledLightMask = {}, 0
    for i = 1, LIGHT_SLOTS do
      local l = lines[base + i]
      local nums = numbers(l.text)
      checkColumns(nums, 7, l.lineNo, context)
      lights[i] = parseLight(nums, l.lineNo, context)
      if lights[i].enabled then
        enabledLightMask = enabledLightMask + 2 ^ (i - 1)
      end
    end

    local colors = {}
    for i = 1, 4 do
      local l = lines[base + LIGHT_SLOTS + i]
      local nums = numbers(l.text)
      checkColumns(nums, 3, l.lineNo, context)
      colors[i] = parseColor(nums, l.lineNo, context)
    end

    records[#records + 1] = {
      startHalfSeconds = startHalfSeconds,
      enabledLightMask = enabledLightMask,
      lights = lights,
      diffuseRgb555 = colors[1],
      ambientRgb555 = colors[2],
      specularRgb555 = colors[3],
      emissionRgb555 = colors[4],
    }
  end

  return { version = FieldLightProfile.VERSION, records = records }
end

-- Select the active record for a wall-clock second-of-day, cyclically: the last
-- record whose threshold <= now, or (before the first threshold) the final
-- record carried over from the previous day.
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
