-- Deterministic serializer for generated Lua data files. Emits a loadable
-- `return <value>` chunk with sorted keys so identical inputs always produce
-- identical output. Pure domain module. Supports nil/boolean/number/string and
-- tables thereof; rejects other types and cyclic references.

local LuaWriter = {}

---@class LuaWriter
---@field encode fun(value: LuaWriter.Value): string

---@alias LuaWriter.Value nil|boolean|number|string|table< number|string, LuaWriter.Value >
---@alias LuaWriter.Key number|string

---@param s string
---@return boolean
local function isIdentifier(s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

---@param s string
---@return string
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
      out[#out + 1] = string.format("\\%03d", b)
    else
      out[#out + 1] = c
    end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

---@param n number
---@return string
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
---@param t table<LuaWriter.Key, LuaWriter.Value>
---@return table<string, unknown>
local function sortedKeys(t)
  local numeric = {} ---@type number[]
  local strings = {} ---@type string[]
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
  local keys = {} ---@type LuaWriter.Key[]
  for _, k in ipairs(numeric) do
    keys[#keys + 1] = k
  end
  for _, k in ipairs(strings) do
    keys[#keys + 1] = k
  end
  return keys
end

local encodeTable
---@type fun(value: LuaWriter.Value, indent: string, seen: table<LuaWriter.Value, boolean>): string
local function encodeValue(value, indent, seen)
  local ty = type(value)
  if ty == "nil" then
    return "nil"
  elseif ty == "boolean" then
    return tostring(value)
  elseif ty == "number" then
    return encodeNumber(value)
  elseif ty == "string" then
    return encodeString(value)
  elseif ty == "table" then
    return encodeTable(value, indent, seen)
  else
    error("cannot serialize value of type: " .. ty)
  end
end

local TABLE_CHUNK_SIZE = 128

---@param key LuaWriter.Key
---@return string
local function encodeKey(key)
  if type(key) == "number" then
    return "[" .. encodeNumber(key) .. "]"
  end
  if isIdentifier(key) then
    return key
  end
  return "[" .. encodeString(key) .. "]"
end

---@param key LuaWriter.Key
---@return string
local function encodeIndex(key)
  if type(key) == "number" then
    return "[" .. encodeNumber(key) .. "]"
  end
  return "[" .. encodeString(key) .. "]"
end

---@param t table<LuaWriter.Key, LuaWriter.Value>
---@param keys LuaWriter.Key[]
---@param indent string
---@param seen table<LuaWriter.Value, boolean>
---@return string
local function encodeChunkedTable(t, keys, indent, seen)
  local inner = indent .. "  "
  local parts = { "(function()\n", inner .. "local result = {}\n", inner .. "local chunk\n" }
  for start = 1, #keys, TABLE_CHUNK_SIZE do
    local finish = math.min(start + TABLE_CHUNK_SIZE - 1, #keys)
    parts[#parts + 1] = inner .. "chunk = (function()\n"
    parts[#parts + 1] = inner .. "  return {\n"
    local chunkIndent = inner .. "    "
    for i = start, finish do
      local key = keys[i]
      parts[#parts + 1] = chunkIndent .. encodeKey(key) .. " = " .. encodeValue(t[key], chunkIndent, seen) .. ",\n"
    end
    parts[#parts + 1] = inner .. "  }\n"
    parts[#parts + 1] = inner .. "end)()\n"
    for i = start, finish do
      local key = keys[i]
      parts[#parts + 1] = inner .. "result" .. encodeIndex(key) .. " = chunk" .. encodeIndex(key) .. "\n"
    end
  end
  parts[#parts + 1] = indent .. "return result\n"
  parts[#parts + 1] = indent .. "end)()"
  return table.concat(parts)
end

---@param t table<LuaWriter.Key, LuaWriter.Value>
---@param indent string
---@param seen table<LuaWriter.Value, boolean>
---@return string
function encodeTable(t, indent, seen)
  if seen[t] then
    error("cannot serialize cyclic table")
  end
  seen[t] = true
  local keys = sortedKeys(t)
  if #keys == 0 then
    seen[t] = nil
    return "{}"
  end
  if #keys > TABLE_CHUNK_SIZE then
    local result = encodeChunkedTable(t, keys, indent, seen)
    seen[t] = nil
    return result
  end
  local inner = indent .. "  "
  local parts = { "{\n" } ---@type string[]
  for i = 1, #keys do
    local k = keys[i]
    parts[#parts + 1] = inner .. encodeKey(k) .. " = " .. encodeValue(t[k], inner, seen) .. ",\n"
  end
  parts[#parts + 1] = indent .. "}"
  seen[t] = nil
  return table.concat(parts)
end

---@param value LuaWriter.Value
---@return string
function LuaWriter.encode(value)
  return "return " .. encodeValue(value, "", {}) .. "\n"
end

return LuaWriter
