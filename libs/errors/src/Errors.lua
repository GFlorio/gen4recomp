-- Structured errors for user-input and binary-format failures. Pure domain
-- module: no love dependency. Programming invariants should use plain assert;
-- these are for malformed ROMs, bad paths, and other recoverable input faults.

local Errors = {}

---@alias Errors.Value string|number|boolean|nil|Errors.Context|Errors.Value[]
---@alias Errors.Context table<string, Errors.Value>
---@class Errors.Error
---@field code string
---@field message string
---@field context Errors.Context

---@class Errors
---@field new fun(code: string, message: string, context?: Errors.Context): Errors.Error
---@field is fun(value: Errors.Error|Errors.Context|string|number|boolean|nil): boolean
---@field format fun(value: Errors.Error|Errors.Context|string|number|boolean|nil): string
---@field raise fun(code: string, message: string, context?: Errors.Context)

local function formatError(errorObject)
  return Errors.format(errorObject)
end

local MT = {
  __index = {},
  __tostring = formatError,
}

---@param code string
---@param message string
---@param context Errors.Context?
---@return Errors.Error
function Errors.new(code, message, context)
  assert(type(code) == "string", "error code must be a string")
  assert(type(message) == "string", "error message must be a string")
  assert(context == nil or type(context) == "table", "context must be a table")
  local result = setmetatable({
    code = code,
    message = message,
    context = context or {},
  }, MT) ---@type Errors.Error
  return result
end

---@param value Errors.Error|Errors.Context|string|number|boolean|nil
---@return boolean
function Errors.is(value)
  return type(value) == "table" and getmetatable(value) == MT
end

---@param value Errors.Context
---@return string[]
local function sortedKeys(value)
  local keys = {} ---@type string[]
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

---@param value Errors.Context|string|number|boolean|nil
---@return string
local function formatValue(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local parts = {}
  for _, key in ipairs(sortedKeys(value)) do
    parts[#parts + 1] = tostring(key) .. "=" .. formatValue(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

---@param value Errors.Error|Errors.Context|string|number|boolean|nil
---@return string
function Errors.format(value)
  if not Errors.is(value) then
    return tostring(value)
  end
  ---@cast value Errors.Error
  local base = value.code .. ": " .. value.message
  if next(value.context) == nil then
    return base
  end
  return base .. " " .. formatValue(value.context)
end

---@param code string
---@param message string
---@param context Errors.Context?
function Errors.raise(code, message, context)
  error(Errors.new(code, message, context))
end

return Errors
