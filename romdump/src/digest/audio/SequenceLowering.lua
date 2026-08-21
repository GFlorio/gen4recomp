-- Lowers decoded SSEQ commands into the project-owned sequence program IR:
-- the shared raw reachability analysis collects the reachable
-- instruction boundaries, branch targets map to instruction indices (never
-- source offsets), and packed operand encodings normalize into asset fields.
-- The FE track-mask byte and its u16 mask are header bytes; the FE header's
-- open-track records are track 0's first commands and stay ordinary
-- instructions, and every reachable open_track destination must be allocated
-- by the mask (the retail corpus never violates this, so the proven track
-- set is checked at compile time and runtime never carries allocation
-- failure). Operands normalize into a single field per command (plain
-- integers or {kind=random lo hi} / {kind=variable var} records) with no
-- artificial u16 truncation: durations and program numbers preserve the full
-- source range, random operands keep the exact signed source pair the parser
-- decoded (never sorted into a min/max range), and the signed operand classes
-- are narrowed to their semantic value (s8 for transpose and pitch_bend, s16
-- for sweep and the variable operations, per the ARM7 NitroSDK player's
-- s8/(s16)TrackParseValue stores) while the true-u16 class (tempo,
-- mod_delay) stays unsigned. Note velocities clamp to the 128-entry SDK
-- volume table. The semantic opcode table follows the ARM7 NitroSDK sequence
-- player: known meaningful opcodes map to semantic names, the reserved SDK
-- no-op classes lower declaratively to explicit nop instructions, the
-- comparison commands (0xB8..0xBD) lower to semantic comparisons, a reachable
-- conditional (0xA2) prefix is preserved as a normalized nested command, the
-- 0xD6 print_var diagnostic (no
-- runtime-observable game behavior) is dropped and never emitted, and a
-- command outside the table is a build failure with source provenance (an
-- unsupported reachable command is never a runtime placeholder). Unreachable
-- bytes are never decoded, so malformed data outside the reachable program
-- cannot fail a build. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local SequenceReachability = require("romdump.src.digest.audio.SequenceReachability")

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
  [0xB8] = "compare",
  [0xB9] = "compare",
  [0xBA] = "compare",
  [0xBB] = "compare",
  [0xBC] = "compare",
  [0xBD] = "compare",
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
-- one table row per opcode. Comparison commands are semantic operations in
-- SEMANTIC_OPS and are therefore intentionally not included in these ranges.
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

-- Whether the FE header's u16 track mask allocates `track` (track 0 is the
-- mask's low bit; the retail corpus always allocates it).
local function trackAllocated(trackMask, track)
  return math.floor(trackMask / 2 ^ track) % 2 == 1
end

-- The signed operand classes (SND_seq.c stores par._s8 for transpose and
-- pitch_bend and casts (s16)TrackParseValue for sweep and the variable
-- operations): a plain u8/u16 operand narrows to its semantic signed value,
-- while a dynamic {kind=random|variable} record keeps its pair (final
-- narrowing of a drawn value is runtime work).
local function toS8(value)
  if type(value) == "number" and value >= 0x80 then
    return value - 0x100
  end
  return value
end

local function toS16(value)
  if type(value) == "number" and value >= 0x8000 then
    return value - 0x10000
  end
  return value
end

-- A random operand keeps the exact signed source pair the parser decoded:
-- the first word is a signed u16 in the SDK's arithmetic, the second word is
-- already signed. The pair is never sorted, never renamed min/max, and never
-- treated as a duration-friendly unsigned range (TrackParseValue is source
-- arithmetic over the raw pair, not math.random(min,max)); the runtime
-- applies the semantic width of the drawn value.
local function randomAmount(value)
  return {
    kind = "random",
    lo = toS16(value.lo),
    hi = toS16(value.hi),
  }
end

-- Normalizes a decoded operand into the closed operand representation: a
-- plain value passes through as an integer (never a clamped placeholder), a
-- random record keeps its exact signed source pair, and a variable record
-- keeps its var reference.
local function normalizeValue(value)
  if type(value) == "number" then
    return value
  end
  if value.kind == "random" then
    return randomAmount(value)
  end
  return value
end

-- Maps a decoded command to its instruction record, or nil when the command
-- is a dropped diagnostic (0xD6 print_var). `indexOf` resolves absolute source
-- offsets to instruction indices for branch targets. Branch operands are
-- sequence-data-relative in the decoded SSEQ and are rebased here.
-- Operands are emitted per
-- semantic op, so reserved no-op forms never carry operand fields; the
-- signed operand classes narrow plain values to their semantic signed
-- number. `trackMask` is the FE header's u16 mask (nil without an FE
-- header): a reachable open_track whose destination the mask does not
-- allocate is a build failure with provenance.
local function toInstruction(command, indexOf, identity, trackMask, dataOffset, targetExecutable)
  local conditional = command.conditional
  if conditional then
    command = setmetatable({ conditional = false }, { __index = command })
  end
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
  if op == "note" then
    instruction.key = opcode
    instruction.velocity = clamp(command.velocity, 0, 0x7F)
    instruction.duration = normalizeValue(command.duration)
  elseif op == "wait" then
    instruction.duration = normalizeValue(command.value)
  elseif op == "program" then
    instruction.program = normalizeValue(command.value)
  elseif op == "open_track" then
    if trackMask == nil or not trackAllocated(trackMask, command.track) then
      Errors.raise(
        "AUDIO_SEQUENCE_TRACK_NOT_ALLOCATED",
        "open_track destination is not allocated by the FE track mask",
        {
          sequenceId = identity.sequenceId,
          sequenceSymbol = identity.symbol,
          sourceOffset = command.offset,
          track = command.track,
        }
      )
    end
    if targetExecutable then
      local absoluteTarget = dataOffset + command.target
      local target = indexOf[absoluteTarget]
      if target == nil then
        Errors.raise("AUDIO_SEQUENCE_BAD_TARGET", "open-track target is not an instruction boundary", {
          sequenceId = identity.sequenceId,
          sequenceSymbol = identity.symbol,
          sourceOffset = command.offset,
          target = absoluteTarget,
          encodedTarget = command.target,
        })
      end
      instruction.target = target
    end
    instruction.track = command.track
  elseif op == "jump" or op == "call" then
    if targetExecutable then
      local absoluteTarget = dataOffset + command.target
      local target = indexOf[absoluteTarget]
      if target == nil then
        Errors.raise("AUDIO_SEQUENCE_BAD_TARGET", "branch target is not an instruction boundary", {
          sequenceId = identity.sequenceId,
          sequenceSymbol = identity.symbol,
          sourceOffset = command.offset,
          target = absoluteTarget,
          encodedTarget = command.target,
        })
      end
      instruction.target = target
    elseif op == "call" then
      -- A saturated CALL is a source no-op. Its target is intentionally not
      -- decoded, so preserve the runtime fallthrough without emitting an
      -- invalid call instruction with no target.
      instruction.op = "nop"
    end
  elseif op ~= "nop" and opcode >= 0xB0 and opcode <= 0xBF then
    instruction.var = command.var
    instruction.amount = toS16(normalizeValue(command.value))
    if op == "compare" then
      instruction.condition = ({
        [0xB8] = "eq",
        [0xB9] = "ge",
        [0xBA] = "gt",
        [0xBB] = "le",
        [0xBC] = "lt",
        [0xBD] = "ne",
      })[opcode]
    end
  elseif op ~= "nop" and opcode >= 0xC0 and opcode <= 0xEF then
    if op == "loop_begin" then
      -- 0xD4 loop_begin: the u8 loop count is a value operand (the player's
      -- loop frame), never an amount field.
      instruction.count = normalizeValue(command.value)
    elseif op == "transpose" or op == "pitch_bend" then
      instruction.amount = toS8(normalizeValue(command.value))
    elseif op == "sweep" then
      instruction.amount = toS16(normalizeValue(command.value))
    else
      instruction.amount = normalizeValue(command.value)
    end
  end
  if conditional then
    return { op = "if", condition = "compare_result", instruction = instruction }
  end
  return instruction
end

local function _lower(bytes, identity, context)
  local source = context or "SSEQ"
  local analysis, reachabilityErr = SequenceReachability.analyze(bytes, source)
  if analysis == nil then
    error(reachabilityErr)
  end
  local dataOffset = analysis.dataOffset
  local entryOffset = analysis.entryOffset
  local trackMask = analysis.trackMask
  local commands = analysis.commandsByOffset

  -- Instruction indices in source-offset order over the emitted instructions
  -- only: dropped diagnostics (print_var) are walked but are not boundaries,
  -- so a branch target landing on one is a build failure with provenance
  -- rather than a silent no-op instruction.
  local offsets = analysis.offsets
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
    instructions[index] =
      toInstruction(commands[offset], indexOf, identity, trackMask, dataOffset, analysis.branchTargets[offset])
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
    initialTrackMask = 1 + (trackMask and math.floor(trackMask / 2) * 2 or 0),
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
