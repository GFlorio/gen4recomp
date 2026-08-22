-- Injectable local civil-time boundary for game policies. The default
-- adapter is the only production owner of the host clock; callers receive a
-- validated copy and independently apply greeting, music, or weather rules.

---@class LocalCivilTime
---@field year integer
---@field month integer
---@field day integer
---@field hour integer
---@field minute integer
---@field second integer

---@class LocalClock
---@field _provider fun(): LocalCivilTime
local LocalClock = {}
LocalClock.__index = LocalClock

local function isInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

local function daysInMonth(year, month)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
    return 29
  end
  return days[month]
end

local function validate(record)
  assert(type(record) == "table", "LocalClock provider must return a civil-time table")
  assert(isInteger(record.year) and record.year >= 1, "LocalClock year must be a positive integer")
  assert(isInteger(record.month) and record.month >= 1 and record.month <= 12, "LocalClock month is invalid")
  assert(
    isInteger(record.day) and record.day >= 1 and record.day <= daysInMonth(record.year, record.month),
    "LocalClock day is invalid"
  )
  assert(isInteger(record.hour) and record.hour >= 0 and record.hour <= 23, "LocalClock hour is invalid")
  assert(isInteger(record.minute) and record.minute >= 0 and record.minute <= 59, "LocalClock minute is invalid")
  assert(isInteger(record.second) and record.second >= 0 and record.second <= 59, "LocalClock second is invalid")
  return {
    year = record.year,
    month = record.month,
    day = record.day,
    hour = record.hour,
    minute = record.minute,
    second = record.second,
  }
end

---@param provider fun(): LocalCivilTime
---@return LocalClock
function LocalClock.new(provider)
  assert(type(provider) == "function", "LocalClock.new requires a provider")
  return setmetatable({ _provider = provider }, LocalClock)
end

---@return LocalCivilTime
function LocalClock:nowLocal()
  return validate(self._provider())
end

---@return LocalClock
function LocalClock.system()
  return LocalClock.new(function()
    ---@diagnostic disable-next-line: return-type-mismatch -- os.date("*t") is the host's civil-time record
    return os.date("*t")
  end)
end

return LocalClock
