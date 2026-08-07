-- Structured errors for user-input and binary-format failures. Pure domain
-- module: no love dependency. Programming invariants should use plain assert;
-- these are for malformed ROMs, bad paths, and other recoverable input faults.

local Errors = {}

---@class Errors.Error
---@field code string
---@field message string
---@field context table

local MT = { __index = {}, __tostring = function(e)
  return Errors.format(e)
end }

function Errors.new(code, message, context)
  assert(type(code) == "string", "error code must be a string")
  assert(type(message) == "string", "error message must be a string")
  assert(context == nil or type(context) == "table", "context must be a table")
  return setmetatable({
    code = code,
    message = message,
    context = context or {},
  }, MT)
end

function Errors.is(value)
  return type(value) == "table" and getmetatable(value) == MT
end

local function sortedKeys(value)
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function formatValue(value)
  if type(value) ~= "table" then return tostring(value) end
  local parts = {}
  for _, key in ipairs(sortedKeys(value)) do
    parts[#parts + 1] = tostring(key) .. "=" .. formatValue(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function Errors.format(value)
  if not Errors.is(value) then return tostring(value) end
  local base = value.code .. ": " .. value.message
  if next(value.context) == nil then return base end
  return base .. " " .. formatValue(value.context)
end

function Errors.raise(code, message, context)
  error(Errors.new(code, message, context))
end

return Errors
