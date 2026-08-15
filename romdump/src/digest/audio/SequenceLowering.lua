-- Lowers decoded SSEQ commands into the project-owned sequence program IR:
-- a fixpoint walk over the command stream (entry points from every branch
-- target, exactly like the inventory scanner) collects the reachable
-- instruction boundaries, branch targets map to instruction indices (never
-- source offsets), and packed operand encodings normalize into asset fields.
-- The FE track-mask byte and its u16 mask are header bytes; the FE header's
-- open-track records are track 0's first commands and stay ordinary
-- instructions. Operands normalize into a single field per command (plain
-- integers or {kind=random min max} / {kind=variable var} records) with no
-- artificial u16 truncation: durations and program numbers preserve the full
-- source range, and random spans keep their full effective pair. Note
-- velocities clamp to the 128-entry SDK volume table. The semantic opcode
-- table follows the ARM7 NitroSDK sequence player: known meaningful opcodes
-- map to semantic names, the reserved SDK no-op classes lower declaratively
-- to explicit nop instructions, the 0xD6 print_var diagnostic (no
-- runtime-observable game behavior) is dropped and never emitted, and a
-- command outside the table is a build failure with source provenance (an
-- unsupported reachable command is never a runtime placeholder).
-- Unreachable bytes are never decoded, so malformed data outside the
-- reachable program cannot fail a build. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local Sseq = require("romdump.src.digest.audio.Sseq")

local SequenceLowering = {}

-- Opcode -> semantic operation name. The 0x00-0x7F notes, the 0x80-0x8F
-- wait/program class, the 0x93-0x95 branch class, and the reserved no-op
-- ranges are handled declaratively below; this table covers the remaining
-- meaningful opcodes.
local SEMANTIC_OPS = {
  [0xB0] = "setvar",
  [0xB1] = "addvar",
  [0xB2] = "subvar",
  [0xB3] = "mulvar",
  [0xB4] = "divvar",
  [0xB5] = "shiftvar",
  [0xB6] = "randomvar",
  [0xB8] = "cmp_eq",
  [0xB9] = "cmp_ge",
  [0xBA] = "cmp_gt",
  [0xBB] = "cmp_le",
  [0xBC] = "cmp_lt",
  [0xBD] = "cmp_ne",
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
  [0xD7] = "mute",
  [0xE0] = "mod_delay",
  [0xE1] = "tempo",
  [0xE3] = "sweep",
  [0xFC] = "loop_end",
  [0xFD] = "return",
  [0xFF] = "end",
}

-- The reserved SDK no-op classes: the NitroSDK player consumes these
-- opcodes without effect, so they lower to explicit nop instructions without
-- one table row per opcode.
local NO_OP_RANGES = {
  { 0x82, 0x8F },
  { 0x90, 0x92 },
  { 0x96, 0x9F },
  { 0xA3, 0xAF },
  { 0xB7, 0xB7 },
  { 0xBE, 0xBF },
  { 0xD8, 0xDF },
  { 0xE2, 0xE2 },
  { 0xE4, 0xEF },
  { 0xF0, 0xFB },
  { 0xFE, 0xFE },
}

local function isReservedNoOp(opcode)
  for _, range in ipairs(NO_OP_RANGES) do
    if opcode >= range[1] and opcode <= range[2] then
      return true
    end
  end
  return false
end

-- The 0xD6 print_var diagnostic: an NNS debug command with no
-- runtime-observable game behavior. The walk consumes it, but lowering never
-- emits it into the closed IR, so a dropped command is not an instruction
-- boundary.
local function isDroppedDiagnostic(opcode)
  return opcode == 0xD6
end

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function failUnsupported(identity, command)
  Errors.raise("AUDIO_SEQUENCE_UNSUPPORTED_COMMAND", "unsupported sequence command", {
    sequenceId = identity.sequenceId,
    sequenceSymbol = identity.symbol,
    sourceOffset = command.offset,
    opcode = string.format("%02X", command.opcode),
  })
end

-- The SDK draws random operands as u16(lo) + (s16(hi) - u16(lo)) * r/65536.
-- For duration-class operands (note/wait) the full span between the raw pair
-- applies; for the byte-class commands the encoder's signed pair is the
-- effective range after the class truncation. Both normalize into the asset
-- operand record without truncating the span.
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
    min = low,
    max = high,
  }
end

-- Normalizes a decoded operand into the closed operand representation: a
-- plain value passes through as an integer (never a clamped placeholder), a
-- random record keeps its full effective span, and a variable record keeps
-- its var reference.
local function normalizeValue(value, isDuration)
  if type(value) == "number" then
    return value
  end
  if value.kind == "random" then
    return randomAmount(value, isDuration)
  end
  return value
end

-- Maps a decoded command to its instruction record, or nil when the command
-- is a dropped diagnostic (0xD6 print_var). `indexOf` resolves source
-- offsets to instruction indices for branch targets. Operands are emitted per
-- semantic op, so reserved no-op forms never carry operand fields.
local function toInstruction(command, indexOf, identity)
  local opcode = command.opcode
  if isDroppedDiagnostic(opcode) then
    return nil
  end
  local op = SEMANTIC_OPS[opcode]
  if op == nil then
    if opcode < 0x80 then
      op = "note"
    elseif opcode == 0x80 then
      op = "wait"
    elseif opcode == 0x81 then
      op = "program"
    elseif opcode == 0x93 then
      op = "open_track"
    elseif opcode == 0x94 then
      op = "jump"
    elseif opcode == 0x95 then
      op = "call"
    elseif isReservedNoOp(opcode) then
      op = "nop"
    else
      failUnsupported(identity, command)
    end
  end
  local instruction = { op = op }
  if command.conditional then
    instruction.conditional = true
  end
  if op == "note" then
    instruction.key = opcode
    instruction.velocity = clamp(command.velocity, 0, 0x7F)
    instruction.duration = normalizeValue(command.duration, true)
  elseif op == "wait" then
    instruction.duration = normalizeValue(command.value, true)
  elseif op == "program" then
    instruction.program = normalizeValue(command.value, true)
  elseif op == "open_track" then
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
  elseif op == "jump" or op == "call" then
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
  elseif op ~= "nop" and opcode >= 0xB0 and opcode <= 0xBF then
    instruction.var = command.var
    instruction.amount = normalizeValue(command.value, false)
  elseif op ~= "nop" and opcode >= 0xC0 and opcode <= 0xEF then
    if op == "loop_begin" then
      -- 0xD4 loop_begin: the u8 loop count is a value operand (the player's
      -- loop frame), never an amount field.
      instruction.count = normalizeValue(command.value, false)
    else
      instruction.amount = normalizeValue(command.value, false)
    end
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

  -- Instruction indices in source-offset order over the emitted instructions
  -- only: dropped diagnostics (print_var) are walked but are not boundaries,
  -- so a branch target landing on one is a build failure with provenance
  -- rather than a silent no-op instruction.
  local offsets = {}
  for offset in pairs(seen) do
    offsets[#offsets + 1] = offset
  end
  table.sort(offsets)
  local emitted = {}
  for _, offset in ipairs(offsets) do
    if not isDroppedDiagnostic(commands[offset].opcode) then
      emitted[#emitted + 1] = offset
    end
  end
  local indexOf = {}
  for index, offset in ipairs(emitted) do
    indexOf[offset] = index
  end
  local instructions = {}
  for index, offset in ipairs(emitted) do
    instructions[index] = toInstruction(commands[offset], indexOf, identity)
  end

  -- The track-0 entry is always walked, but a dropped diagnostic at the
  -- entry never becomes an instruction: like a branch target landing on a
  -- dropped command, it is a build failure with provenance, never a silent
  -- fall-through into the following instruction.
  local entry = indexOf[entryOffset]
  if entry == nil then
    Errors.raise("AUDIO_SEQUENCE_BAD_TARGET", "sequence entry lands on a dropped instruction", {
      sequenceId = identity.sequenceId,
      sequenceSymbol = identity.symbol,
      sourceOffset = entryOffset,
    })
  end

  return {
    entry = entry,
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
