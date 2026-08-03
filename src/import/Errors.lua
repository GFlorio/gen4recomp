-- Structured errors for user-input and binary-format failures. Pure domain
-- module: no love dependency. Programming invariants should use plain assert;
-- these are for malformed ROMs, bad paths, and other recoverable input faults.

local Errors = {}

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

function Errors.format(value)
  if not Errors.is(value) then return tostring(value) end
  return value.code .. ": " .. value.message
end

function Errors.raise(code, message, context)
  error(Errors.new(code, message, context))
end

return Errors
