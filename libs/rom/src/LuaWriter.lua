-- Deterministic serializer for generated Lua data files. Emits a loadable
-- `return <value>` chunk with sorted keys so identical inputs always produce
-- identical output. Pure domain module. Supports nil/boolean/number/string and
-- tables thereof; rejects other types and cyclic references.

local LuaWriter = {}

local function isIdentifier(s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function encodeString(s)
  local out = { '"' }
  for i = 1, #s do
    local b = string.byte(s, i)
    local c = string.sub(s, i, i)
    if c == '"' then
      out[#out + 1] = '\\"'
    elseif c == "\\" then
      out[#out + 1] = "\\\\"
    elseif c == "\n" then
      out[#out + 1] = "\\n"
    elseif c == "\r" then
      out[#out + 1] = "\\r"
    elseif c == "\t" then
      out[#out + 1] = "\\t"
    elseif b < 32 or b == 127 then
      out[#out + 1] = string.format("\\%d", b)
    else
      out[#out + 1] = c
    end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("cannot serialize non-finite number: " .. tostring(n))
  end
  if n % 1 == 0 then
    return string.format("%d", n)
  end
  return string.format("%.17g", n)
end

-- Sort keys deterministically: numbers ascending, then strings alphabetically.
local function sortedKeys(t)
  local numeric, strings = {}, {}
  for k in pairs(t) do
    if type(k) == "number" then
      numeric[#numeric + 1] = k
    elseif type(k) == "string" then
      strings[#strings + 1] = k
    else
      error("unsupported table key type: " .. type(k))
    end
  end
  table.sort(numeric)
  table.sort(strings)
  local keys = {}
  for _, k in ipairs(numeric) do
    keys[#keys + 1] = k
  end
  for _, k in ipairs(strings) do
    keys[#keys + 1] = k
  end
  return keys
end

local encodeValue

local function encodeTable(t, indent, seen)
  if seen[t] then
    error("cannot serialize cyclic table")
  end
  seen[t] = true
  local keys = sortedKeys(t)
  if #keys == 0 then
    seen[t] = nil
    return "{}"
  end
  local inner = indent .. "  "
  local parts = { "{\n" }
  for _, k in ipairs(keys) do
    local keyStr
    if type(k) == "number" then
      keyStr = "[" .. encodeNumber(k) .. "]"
    elseif isIdentifier(k) then
      keyStr = k
    else
      keyStr = "[" .. encodeString(k) .. "]"
    end
    parts[#parts + 1] = inner .. keyStr .. " = " .. encodeValue(t[k], inner, seen) .. ",\n"
  end
  parts[#parts + 1] = indent .. "}"
  seen[t] = nil
  return table.concat(parts)
end

encodeValue = function(v, indent, seen)
  local ty = type(v)
  if ty == "nil" then
    return "nil"
  elseif ty == "boolean" then
    return tostring(v)
  elseif ty == "number" then
    return encodeNumber(v)
  elseif ty == "string" then
    return encodeString(v)
  elseif ty == "table" then
    return encodeTable(v, indent, seen)
  else
    error("cannot serialize value of type: " .. ty)
  end
end

function LuaWriter.encode(value)
  return "return " .. encodeValue(value, "", {}) .. "\n"
end

return LuaWriter
