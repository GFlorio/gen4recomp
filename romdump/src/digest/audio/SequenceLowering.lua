-- Lowers decoded SSEQ commands into the project-owned sequence program IR:
-- a fixpoint walk over the command stream (entry points from every branch
-- target, exactly like the inventory scanner) collects the reachable
-- instruction boundaries, branch targets map to instruction indices (never
-- source offsets), and packed operand encodings normalize into asset fields.
-- The FE track-mask byte and its u16 mask are header bytes; the FE header's
-- open-track records are track 0's first commands and stay ordinary
-- instructions. Note velocities clamp to the 128-entry SDK volume table and
-- durations/program numbers clamp to the asset's u16 range. The semantic
-- opcode table follows the ARM7 NitroSDK sequence player: commands the
-- player treats as no-ops (reserved classes, 0x82-0x8F, 0x90-0x9F beyond
-- 0x93-0x95, 0xA3-0xAF, 0xF0-0xFB, 0xFE) lower to explicit nop instructions,
-- and a command outside the table is a build failure with source provenance
-- (an unsupported reachable command is never a runtime placeholder).
-- Unreachable bytes are never decoded, so malformed data outside the
-- reachable program cannot fail a build. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local Sseq = require("romdump.src.digest.audio.Sseq")

local SequenceLowering = {}

-- Opcode -> semantic operation name. The 0x00-0x7F notes and the 0x80-0x8F
-- class are handled structurally; the table covers every other opcode.
local OP_NAMES = {
  [0x82] = "nop",
  [0x83] = "nop",
  [0x84] = "nop",
  [0x85] = "nop",
  [0x86] = "nop",
  [0x87] = "nop",
  [0x88] = "nop",
  [0x89] = "nop",
  [0x8A] = "nop",
  [0x8B] = "nop",
  [0x8C] = "nop",
  [0x8D] = "nop",
  [0x8E] = "nop",
  [0x8F] = "nop",
  [0x90] = "nop",
  [0x91] = "nop",
  [0x92] = "nop",
  [0x93] = "open_track",
  [0x94] = "jump",
  [0x95] = "call",
  [0x96] = "nop",
  [0x97] = "nop",
  [0x98] = "nop",
  [0x99] = "nop",
  [0x9A] = "nop",
  [0x9B] = "nop",
  [0x9C] = "nop",
  [0x9D] = "nop",
  [0x9E] = "nop",
  [0x9F] = "nop",
  [0xA3] = "nop",
  [0xA4] = "nop",
  [0xA5] = "nop",
  [0xA6] = "nop",
  [0xA7] = "nop",
  [0xA8] = "nop",
  [0xA9] = "nop",
  [0xAA] = "nop",
  [0xAB] = "nop",
  [0xAC] = "nop",
  [0xAD] = "nop",
  [0xAE] = "nop",
  [0xAF] = "nop",
  [0xB0] = "setvar",
  [0xB1] = "addvar",
  [0xB2] = "subvar",
  [0xB3] = "mulvar",
  [0xB4] = "divvar",
  [0xB5] = "shiftvar",
  [0xB6] = "randomvar",
  [0xB7] = "nop",
  [0xB8] = "cmp_eq",
  [0xB9] = "cmp_ge",
  [0xBA] = "cmp_gt",
  [0xBB] = "cmp_le",
  [0xBC] = "cmp_lt",
  [0xBD] = "cmp_ne",
  [0xBE] = "nop",
  [0xBF] = "nop",
  [0xC0] = "pan",
  [0xC1] = "volume",
  [0xC2] = "master_volume",
  [0xC3] = "transpose",
  [0xC4] = "pitch_bend",
  [0xC5] = "pitch_bend_range",
  [0xC6] = "priority",
  [0xC7] = "note_wait",
  [0xC8] = "tie",
  [0xC9] = "portamento_key",
  [0xCA] = "mod_depth",
  [0xCB] = "mod_speed",
  [0xCC] = "mod_type",
  [0xCD] = "mod_range",
  [0xCE] = "portamento",
  [0xCF] = "portamento_time",
  [0xD0] = "attack",
  [0xD1] = "decay",
  [0xD2] = "sustain",
  [0xD3] = "release",
  [0xD4] = "loop_begin",
  [0xD5] = "expression",
  [0xD6] = "print_var",
  [0xD7] = "mute",
  [0xD8] = "nop",
  [0xD9] = "nop",
  [0xDA] = "nop",
  [0xDB] = "nop",
  [0xDC] = "nop",
  [0xDD] = "nop",
  [0xDE] = "nop",
  [0xDF] = "nop",
  [0xE0] = "mod_delay",
  [0xE1] = "tempo",
  [0xE2] = "nop",
  [0xE3] = "sweep",
  [0xE4] = "nop",
  [0xE5] = "nop",
  [0xE6] = "nop",
  [0xE7] = "nop",
  [0xE8] = "nop",
  [0xE9] = "nop",
  [0xEA] = "nop",
  [0xEB] = "nop",
  [0xEC] = "nop",
  [0xED] = "nop",
  [0xEE] = "nop",
  [0xEF] = "nop",
  [0xF0] = "nop",
  [0xF1] = "nop",
  [0xF2] = "nop",
  [0xF3] = "nop",
  [0xF4] = "nop",
  [0xF5] = "nop",
  [0xF6] = "nop",
  [0xF7] = "nop",
  [0xF8] = "nop",
  [0xF9] = "nop",
  [0xFA] = "nop",
  [0xFB] = "nop",
  [0xFC] = "loop_end",
  [0xFD] = "return",
  [0xFE] = "nop",
  [0xFF] = "end",
}

-- The asset contract constrains value fields to the ranges the runtime can
-- represent: note velocity is the index of a 128-entry SDK volume table (raw
-- bytes above 127 read past it), and durations/program numbers are u16. The
-- real archive contains velocities above 127 and multi-byte varlen durations
-- beyond 0xFFFF (including header-crossing decodes), so the lowering clamps
-- plain values into the representable range; normalized random/variable
-- amounts keep their raw ranges in `amount` with a clamped placeholder in
-- the value field.
local DURATION_MAX = 0xFFFF

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

-- The SDK draws random operands as u16(lo) + (s16(hi) - u16(lo)) * r/65536.
-- For duration-class operands (note/wait) the full span applies; for the
-- byte-class commands the encoder's signed pair is the effective range after
-- the class truncation. Both normalize into the asset's +-0x8000 range.
local function randomAmount(value, isDuration)
  local s16lo = value.lo >= 0x8000 and value.lo - 0x10000 or value.lo
  local low, high
  if isDuration then
    low, high = math.min(value.lo, value.hi), math.max(value.lo, value.hi)
  elseif s16lo <= value.hi then
    low, high = s16lo, value.hi
  else
    low, high = math.min(value.lo, value.hi), math.max(value.lo, value.hi)
  end
  return {
    kind = "random",
    min = clamp(low, -0x8000, 0x7FFF),
    max = clamp(high, -0x8000, 0x7FFF),
  }
end

-- Amounts on byte-class commands: plain values pass through; random records
-- normalize into the signed min/max range.
local function amountValue(value)
  if type(value) == "table" and value.kind == "random" then
    return randomAmount(value, false)
  end
  return value
end

-- Normalizes a decoded operand: plain values pass through clamped into the
-- value field's range; random records keep a clamped placeholder in the
-- value field with the normalized range in `amount`; variable records get a
-- zero placeholder value with the variable reference in `amount`.
-- Returns value, amount.
local function normalizeValue(value, high, isDuration)
  if type(value) == "number" then
    return clamp(value, 0, high), nil
  end
  if value.kind == "random" then
    local amount = randomAmount(value, isDuration)
    return clamp(amount.min, 0, high), amount
  end
  return 0, value
end

local function failUnsupported(identity, command)
  Errors.raise("AUDIO_SEQUENCE_UNSUPPORTED_COMMAND", "unsupported sequence command", {
    sequenceId = identity.sequenceId,
    sequenceSymbol = identity.symbol,
    sourceOffset = command.offset,
    opcode = string.format("%02X", command.opcode),
  })
end

-- Maps a decoded command to its instruction record. `indexOf` resolves
-- source offsets to instruction indices for branch targets.
local function toInstruction(command, indexOf, identity)
  local opcode = command.opcode
  local instruction = { op = OP_NAMES[opcode] }
  if instruction.op == nil then
    if opcode < 0x80 then
      instruction.op = "note"
    elseif opcode == 0x80 then
      instruction.op = "wait"
    elseif opcode == 0x81 then
      instruction.op = "program"
    else
      failUnsupported(identity, command)
    end
  end
  if command.conditional then
    instruction.conditional = true
  end
  if opcode < 0x80 then
    local duration, amount = normalizeValue(command.duration, DURATION_MAX, true)
    instruction.key = opcode
    instruction.velocity = clamp(command.velocity, 0, 0x7F)
    instruction.duration = duration
    if amount ~= nil then
      instruction.amount = amount
    end
  elseif opcode <= 0x8F then
    local value, amount = normalizeValue(command.value, DURATION_MAX, true)
    if opcode == 0x80 then
      instruction.duration = value
    elseif opcode == 0x81 then
      instruction.program = value
    end
    if amount ~= nil then
      instruction.amount = amount
    end
  elseif opcode == 0x93 then
    local target = indexOf[command.target]
    if target == nil then
      Errors.raise("AUDIO_SEQUENCE_BAD_TARGET", "open-track target is not an instruction boundary", {
        sequenceId = identity.sequenceId,
        sequenceSymbol = identity.symbol,
        sourceOffset = command.offset,
        target = command.target,
      })
    end
    instruction.track = command.track
    instruction.target = target
  elseif opcode == 0x94 or opcode == 0x95 then
    local target = indexOf[command.target]
    if target == nil then
      Errors.raise("AUDIO_SEQUENCE_BAD_TARGET", "branch target is not an instruction boundary", {
        sequenceId = identity.sequenceId,
        sequenceSymbol = identity.symbol,
        sourceOffset = command.offset,
        target = command.target,
      })
    end
    instruction.target = target
  elseif opcode <= 0xBF then
    instruction.var = command.var
    instruction.amount = amountValue(command.value)
  elseif opcode <= 0xEF then
    instruction.amount = amountValue(command.value)
  end
  return instruction
end

local function _lower(bytes, identity, context)
  local source = context or "SSEQ"
  local seq, err = Sseq.open(bytes, source)
  if seq == nil then
    error(err)
  end
  seq = assert(seq)
  local endPos = #bytes
  local dataOffset = seq.dataOffset

  -- The FE byte and its u16 track mask are header bytes; everything after
  -- them (including the FE header's open-track records, which are track 0's
  -- first commands) is code. Branch targets queued while walking make every
  -- reachable instruction an entry point, so targets before the data offset
  -- (into the header region) are ordinary targets that decode header bytes
  -- as code exactly like the inventory scanner.
  local pos = dataOffset
  if pos < endPos and string.byte(bytes, pos + 1) == 0xFE then
    pos = pos + 3
    if pos > endPos then
      Errors.raise("SSEQ_TRUNCATED", "track mask runs past the end of the sequence", {
        source = source,
        offset = dataOffset,
      })
    end
  end
  local entryOffset = pos
  if entryOffset >= endPos then
    Errors.raise("SSEQ_TRUNCATED", "sequence contains no commands", {
      source = source,
      offset = entryOffset,
    })
  end

  local queue = { pos }
  local seen = {}
  local commands = {}
  while #queue > 0 do
    local start = table.remove(queue)
    if not seen[start] and start < endPos then
      pos = start
      while pos < endPos and not seen[pos] do
        seen[pos] = true
        local command, cmdErr = Sseq.decodeCommand(bytes, pos, endPos, source)
        if command == nil then
          error(cmdErr)
        end
        commands[pos] = command
        pos = command.next
        local opcode = command.opcode
        if opcode == 0x93 or opcode == 0x94 or opcode == 0x95 then
          queue[#queue + 1] = command.target
        end
        if opcode == 0x94 or opcode == 0xFF or opcode == 0xFD then
          break
        end
      end
    end
  end

  -- Instruction indices in source-offset order; every branch target must be
  -- one of these boundaries.
  local offsets = {}
  for offset in pairs(seen) do
    offsets[#offsets + 1] = offset
  end
  table.sort(offsets)
  local indexOf = {}
  for index, offset in ipairs(offsets) do
    indexOf[offset] = index
  end
  local instructions = {}
  for index, offset in ipairs(offsets) do
    instructions[index] = toInstruction(commands[offset], indexOf, identity)
  end

  return {
    entry = assert(indexOf[entryOffset], "the track-0 entry is always walked"),
    instructions = instructions,
  }
end

---@param bytes string
---@param identity { sequenceId: integer, symbol: string? }
---@param context string?
---@return table?|nil
---@return Errors.Error?|nil
function SequenceLowering.lower(bytes, identity, context)
  local ok, result = pcall(_lower, bytes, identity, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return SequenceLowering
