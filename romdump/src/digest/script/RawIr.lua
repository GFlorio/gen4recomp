-- Raw instruction IR : the mode-independent output of the
-- decomp parser and the binary decoder. Both producers emit exactly this
-- shape so semantic lowering and verification never care where the bytes came
-- from. Pure domain module: no love dependency.

local RawIr = {}

RawIr.SCHEMA_NAME = "g4-hgss-raw-ir-v1"

-- Build one instruction record.
---@param offset integer
---@param opcode integer
---@param name string
---@param operands table[]
---@param size integer
---@param label string|nil
---@return table
function RawIr.instruction(offset, opcode, name, operands, size, label)
  return {
    offset = offset,
    opcode = opcode,
    name = name,
    operands = operands,
    size = size,
    label = label,
  }
end

-- Build one movement action record .
---@param offset integer
---@param movementCode integer|nil
---@param name string
---@param count integer
---@return table
function RawIr.movementAction(offset, movementCode, name, count)
  return {
    offset = offset,
    movementCode = movementCode,
    name = name,
    count = count,
  }
end

-- A parsed script member: scripts by ScrDef index and movement blocks by
-- referenced offset.
---@param member integer
---@param sourcePath string
---@param sourceHash string|nil
---@return table
function RawIr.member(member, sourcePath, sourceHash)
  return {
    schema = RawIr.SCHEMA_NAME,
    member = member,
    sourcePath = sourcePath,
    sourceHash = sourceHash,
    scripts = {},
    movements = {},
  }
end

return RawIr
