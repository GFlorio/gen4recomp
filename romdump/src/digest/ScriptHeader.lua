-- Decodes the complete typed HGSS map-init script stream and its referenced
-- OnFrame tables. The producer owns these source offsets and binary forms.

local Errors = require("libs.errors.src.Errors")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")

local ScriptHeader = {}

local function fail(message, context)
  Errors.raise("SCRIPT_HEADER_INVALID", message, context)
end

local function byte(bytes, offset)
  return bytes:byte(offset + 1)
end

local function u16(bytes, offset)
  local a, b = bytes:byte(offset + 1, offset + 2)
  if not a or not b then
    return nil
  end
  return a + b * 256
end

local function i32(bytes, offset)
  local a, b, c, d = bytes:byte(offset + 1, offset + 4)
  if not d then
    return nil
  end
  local value = a + b * 256 + c * 65536 + d * 16777216
  return value >= 2147483648 and value - 4294967296 or value
end

local function context(opts, sourceOffset, typeId)
  return { mapId = opts.mapId, memberId = opts.memberId, type = typeId, sourceOffset = sourceOffset }
end

local function scriptId(opts, rawScriptId, sourceOffset, typeId)
  if rawScriptId == nil or rawScriptId < 1 then
    fail("script ID must be at least one", context(opts, sourceOffset, typeId))
  end
  return ScriptIdentity.formatVanilla(opts.scriptBankId or 0, rawScriptId - 1)
end

local function parseTable(bytes, offset, opts, typeId)
  if offset < 0 or offset + 2 > #bytes then
    fail("OnFrame table pointer is outside the script header", context(opts, offset, typeId))
  end
  local rules = {}
  local cursor = offset
  while true do
    local variableId = u16(bytes, cursor)
    if variableId == nil then
      fail("unterminated OnFrame equality table", context(opts, cursor, typeId))
    end
    if variableId == 0 then
      return rules, cursor + 2
    end
    local equals = u16(bytes, cursor + 2)
    local rawScriptId = u16(bytes, cursor + 4)
    if equals == nil or rawScriptId == nil then
      fail("truncated OnFrame equality entry", context(opts, cursor, typeId))
    end
    rules[#rules + 1] = {
      variableId = variableId,
      equals = equals,
      scriptId = scriptId(opts, rawScriptId, cursor + 4, typeId),
    }
    cursor = cursor + 6
  end
end

local FIXED_TYPES = { [2] = "on_transition", [3] = "on_resume", [4] = "on_load" }

---@param bytes string
---@param opts table<string, unknown>|nil { mapId: integer, memberId: integer, scriptBankId: integer }
---@return table<string, unknown>
function ScriptHeader.parse(bytes, opts)
  assert(type(bytes) == "string", "script header bytes must be a string")
  opts = opts or {}
  if #bytes == 0 then
    return {}
  end
  local descriptors = {}
  local tables = {}
  local cursor = 0
  while true do
    local typeId = byte(bytes, cursor)
    if typeId == nil then
      fail("unterminated init-script entry stream", context(opts, cursor, nil))
    end
    if typeId == 0 then
      break
    end
    if typeId == 1 then
      local displacement = i32(bytes, cursor + 1)
      if displacement == nil then
        fail("truncated OnFrame entry", context(opts, cursor, typeId))
      end
      tables[#tables + 1] = { descriptor = #descriptors + 1, offset = cursor + 5 + displacement, type = typeId }
      descriptors[#descriptors + 1] = { type = "on_frame_eq" }
      cursor = cursor + 5
    else
      local name = FIXED_TYPES[typeId]
      if not name then
        fail("unknown init-script entry type", context(opts, cursor, typeId))
      end
      local rawScriptId = u16(bytes, cursor + 1)
      local reserved = u16(bytes, cursor + 3)
      if rawScriptId == nil or reserved == nil then
        fail("truncated fixed init-script entry", context(opts, cursor, typeId))
      end
      if reserved ~= 0 then
        fail("fixed init-script entry has nonzero reserved field", context(opts, cursor, typeId))
      end
      descriptors[#descriptors + 1] = {
        type = name,
        scriptId = scriptId(opts, rawScriptId, cursor + 1, typeId),
      }
      cursor = cursor + 5
    end
  end
  for _, reference in ipairs(tables) do
    local rules, endOffset = parseTable(bytes, reference.offset, opts, reference.type)
    descriptors[reference.descriptor].rules = rules
    reference.endOffset = endOffset
  end
  for offset = cursor + 1, #bytes - 1 do
    if byte(bytes, offset) ~= 0 then
      local inTable = false
      for _, reference in ipairs(tables) do
        if offset >= reference.offset and offset < reference.endOffset then
          inTable = true
          break
        end
      end
      if not inTable then
        fail("nonzero data follows init-script entry stream", context(opts, offset, nil))
      end
    end
  end
  return descriptors
end

return ScriptHeader
