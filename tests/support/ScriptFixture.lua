-- Synthetic retail-format scr_seq member builder for script-translator tests.
-- Builds the exact retail layout the binary decoder consumes: a table of
-- relative u32 entries (entry[i] = scriptOffset - entryPos - 4), a u16
-- 0xFD13 sentinel, and script/movement bytes at arbitrary offsets. Branch and
-- ApplyMovement operands marked `target` are emitted as signed relative word
-- offsets from the end of the instruction, matching the retail encoding.

local ScriptFixture = {}

local SCRDEF_END = 0xFD13

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

-- Encode one instruction at `cursor`; returns the byte blob plus its size.
-- `args` entries are `{ value = number, width = number }` or
-- `{ target = number, width = 4 }` (a relative word from the end of the
-- instruction to the absolute target offset).
---@param instruction table
---@param cursor integer
---@return string bytes, integer size
local function encodeInstruction(instruction, cursor)
  local parts = { u16(instruction.op) }
  local size = 2
  for _, arg in ipairs(instruction.args or {}) do
    local value = arg.value
    local width = arg.width or 2
    if arg.target ~= nil then
      value = arg.target - (cursor + size + width)
    end
    if width == 1 then
      parts[#parts + 1] = string.char(value % 256)
    elseif width == 2 then
      parts[#parts + 1] = u16(value % 65536)
    else
      local normalized = value
      if normalized < 0 then
        normalized = normalized + 0x100000000
      end
      parts[#parts + 1] = u32(normalized)
    end
    size = size + width
  end
  return table.concat(parts), size
end

-- Build one member. `specs` is a list of script specs:
--   { offset = number, instructions = { { op, args } }, }
-- plus `movements` = { { offset = number, actions = { { code, args } } } }.
---@param specs table
---@return string bytes
function ScriptFixture.member(specs)
  local scripts = specs.scripts or specs
  local movements = specs.movements or {}
  local parts = {}
  local function putAt(offset, bytes)
    parts[#parts + 1] = string.rep("\0", offset - #table.concat(parts))
    parts[#parts + 1] = bytes
  end
  -- Entry table first: one relative entry per script (in index order).
  local entries = {}
  for i, script in ipairs(scripts) do
    entries[#entries + 1] = u32(script.offset - (i - 1) * 4 - 4)
  end
  parts[#parts + 1] = table.concat(entries) .. u16(SCRDEF_END) .. u16(0)
  -- Script bytes at their offsets (padding between).
  for _, script in ipairs(scripts) do
    local blob = {}
    local cursor = script.offset
    for _, instruction in ipairs(script.instructions) do
      local bytes, size = encodeInstruction(instruction, cursor)
      blob[#blob + 1] = bytes
      cursor = cursor + size
    end
    putAt(script.offset, table.concat(blob))
  end
  -- Movement blocks at their offsets.
  for _, movement in ipairs(movements) do
    local blob = {}
    local cursor = movement.offset
    for _, action in ipairs(movement.actions) do
      blob[#blob + 1] = u16(action.code)
      for _, arg in ipairs(action.args or {}) do
        blob[#blob + 1] = u16(arg)
      end
      cursor = cursor + 2 + 2 * #(action.args or {})
    end
    putAt(movement.offset, table.concat(blob))
  end
  return table.concat(parts)
end

return ScriptFixture
