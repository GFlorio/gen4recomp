-- Decodes the type-1 HGSS field-script header records used by map initialization.
-- The producer owns this source representation; runtime receives only ordered
-- OnFrame equality rules.

local Errors = require("libs.errors.src.Errors")

local ScriptHeader = {}

local function u16(bytes, offset)
  local a, b = bytes:byte(offset + 1, offset + 2)
  if not a or not b then
    return nil
  end
  return a + b * 256
end

local function fail(message, context)
  Errors.raise("SCRIPT_HEADER_INVALID", message, context)
end

---@param bytes string
---@param opts table { mapId: integer, memberId: integer, scriptBankId: integer }
---@return table
function ScriptHeader.parse(bytes, opts)
  assert(type(bytes) == "string", "script header bytes must be a string")
  opts = opts or {}
  local context = { mapId = opts.mapId, memberId = opts.memberId }
  if #bytes == 0 then
    return {}
  end
  if #bytes < 8 then
    fail("truncated type-1 script header", context)
  end
  if bytes:byte(1) ~= 1 or bytes:byte(2) ~= 1 then
    fail("unsupported script-header type", context)
  end
  if bytes:sub(3, 6) ~= "\0\0\0\0" then
    fail("malformed type-1 script-header prefix", context)
  end

  local cursor = 6
  local rules = {}
  local terminated = false
  local index = 0
  while cursor + 2 <= #bytes do
    if u16(bytes, cursor) == 0 then
      cursor = cursor + 2
      terminated = true
      break
    end
    local variableId = u16(bytes, cursor)
    local equals = u16(bytes, cursor + 2)
    if variableId == nil or equals == nil then
      fail("truncated OnFrame equality entry", { mapId = opts.mapId, memberId = opts.memberId, entry = index })
    end
    cursor = cursor + 4
    local target = u16(bytes, cursor)
    if target == nil then
      fail("truncated OnFrame script target", { mapId = opts.mapId, memberId = opts.memberId, entry = index })
    end
    cursor = cursor + 2
    local scriptIndex = target - 1
    rules[#rules + 1] = {
      variableId = variableId,
      equals = equals,
      scriptIndex = scriptIndex,
      scriptId = string.format("vanilla.hgss.scr_seq.%04d.script_%03d", opts.scriptBankId or 0, scriptIndex),
    }
    index = index + 1
  end
  if not terminated or cursor ~= #bytes then
    fail("unterminated or trailing type-1 script-header records", context)
  end
  return { { type = "on_frame_eq", rules = rules } }
end

return ScriptHeader
