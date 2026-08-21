-- Validator for the derived audio sequence asset: numeric and symbolic
-- identity, a bank reference, a player block, and a program whose branch
-- targets are instruction indices, never source offsets. The instruction
-- vocabulary is closed: every emitted op is a member of the semantic set
-- (the lowering emits nothing else), each op carries exactly its operand(s)
-- and no other fields, and every operand is normalized to a plain integer,
-- {kind=random lo hi}, or {kind=variable var}. Random operands keep the
-- exact signed source pair: both endpoints are integers in the signed-16
-- domain, never sorted or renamed min/max, and the record carries no extra
-- keys. Source value ranges survive (durations and program numbers are not
-- truncated to u16), so the validator rejects only impossible shapes: unknown
-- or deleted ops, missing or illegally shaped operands, extra keys anywhere --
-- including on the nested operand records -- variables without a valid
-- variable number (0..31: 16 player-local plus 16 global SDK variables),
-- track numbers outside 0..15, out-of-range branch targets, note
-- key/velocity outside 0..127, malformed conditional instructions, and extra
-- instruction or nested-block fields (an instruction carries only its op
-- and its exact semantic operands; player only its supported fields;
-- program entry, initialTrackMask, and instructions). Source provenance may ride along at
-- the sequence level for diagnostics but is never behavior-visible.

local AudioSequence = {}

local Validate = require("libs.assets.src.Validate")
local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.assets.src.AudioErrors")
local Contract = require("libs.assets.src.DerivedAssetContract")

AudioSequence.SCHEMA = Contract.audio.sequenceSchema

-- The closed semantic operation vocabulary shared by the lowering and the
-- player. `rest` and `print_var` are deliberately absent: no producer emits
-- a semantic rest (SSEQ WAIT models the behavior), and print_var is an NNS
-- diagnostic dropped during lowering. Comparisons and conditional nested
-- commands remain part of the normalized contract.
local OPS = {
  note = { "key", "velocity", "duration" },
  wait = { "duration" },
  program = { "program" },
  open_track = { "track", "target" },
  jump = { "target" },
  call = { "target" },
  ["return"] = {},
  setvar = { "var", "amount" },
  addvar = { "var", "amount" },
  subvar = { "var", "amount" },
  mulvar = { "var", "amount" },
  divvar = { "var", "amount" },
  shiftvar = { "var", "amount" },
  randomvar = { "var", "amount" },
  compare = { "condition", "var", "amount" },
  ["if"] = { "condition", "instruction" },
  pan = { "amount" },
  volume = { "amount" },
  master_volume = { "amount" },
  transpose = { "amount" },
  pitch_bend = { "amount" },
  pitch_bend_range = { "amount" },
  priority = { "amount" },
  note_wait = { "amount" },
  tie = { "amount" },
  portamento_key = { "amount" },
  portamento = { "amount" },
  portamento_time = { "amount" },
  mod_depth = { "amount" },
  mod_speed = { "amount" },
  mod_type = { "amount" },
  mod_range = { "amount" },
  mod_delay = { "amount" },
  attack = { "amount" },
  decay = { "amount" },
  sustain = { "amount" },
  release = { "amount" },
  loop_begin = { "count" },
  loop_end = {},
  expression = { "amount" },
  sweep = { "amount" },
  mute = { "amount" },
  tempo = { "amount" },
  ["end"] = {},
  nop = {},
}

-- The SDK variable domain: vars 0..15 address the player-local variables,
-- 16..31 the shared global variables (the pokediamond decomp SND_work_shared
-- layout: localVars[16] per player plus globalVars[16]).
local VARIABLE_MAX = 31
-- The SDK track domain: 16 tracks per player (the u16 FE track mask).
local TRACK_MAX = 15
local COMPARE_CONDITIONS = { eq = true, ge = true, gt = true, le = true, lt = true, ne = true }

local function fail(context)
  Errors.raise(AudioErrors.AUDIO_SEQUENCE_INVALID, "malformed audio sequence asset", context)
end

-- Rejects a record carrying any key outside the allowed set: instruction
-- shapes are exact, so a raw opcode, a source offset, a mode marker, or any
-- other source-leak field is malformed asset data, never tolerated.
---@param record table
---@param allowed table<string, boolean>
---@param field string
local function assertOnlyKeys(record, allowed, field)
  for key in pairs(record) do
    if not allowed[key] then
      fail({ field = field, key = key })
    end
  end
end

local function isIntegerInRange(value, low, high)
  return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

local function isKey(value)
  return isIntegerInRange(value, 0, 0x7F)
end

local function isTarget(value, count)
  return isIntegerInRange(value, 1, count)
end

-- A normalized operand: a plain integer, a random {lo, hi} pair (both
-- endpoints integers in the signed-16 domain, descending pairs included --
-- the source operation is not a sorted range so no ordering is enforced), or
-- a variable {var} record with a valid variable number. Every record is a
-- closed shape: extra keys (including the retired min/max names) are
-- malformed. The optional nonNegative constraint applies to the plain
-- integer form only; random endpoints keep the exact signed source pair.
---@param amount any
---@param nonNegative boolean?
local function isValidOperand(amount, nonNegative)
  if type(amount) == "number" then
    if amount % 1 ~= 0 then
      return false
    end
    return not nonNegative or amount >= 0
  end
  if type(amount) ~= "table" then
    return false
  end
  if amount.kind == "variable" then
    for key in pairs(amount) do
      if key ~= "kind" and key ~= "var" then
        return false
      end
    end
    return isIntegerInRange(amount.var, 0, VARIABLE_MAX)
  end
  if amount.kind == "random" then
    for key in pairs(amount) do
      if key ~= "kind" and key ~= "lo" and key ~= "hi" then
        return false
      end
    end
    return isIntegerInRange(amount.lo, -0x8000, 0x7FFF) and isIntegerInRange(amount.hi, -0x8000, 0x7FFF)
  end
  return false
end

local function validateNestedInstruction(instruction, field, instructionCount)
  if type(instruction) ~= "table" or type(instruction.op) ~= "string" then
    fail({ field = field .. ".op" })
  end
  local op = instruction.op
  local operandSpec = OPS[op]
  if operandSpec == nil or op == "if" then
    fail({ field = field .. ".op", op = op })
  end
  operandSpec = operandSpec --[[@as table]]
  local allowed = { op = true }
  for _, operand in ipairs(operandSpec) do
    allowed[operand] = true
  end
  assertOnlyKeys(instruction, allowed, field)
  for _, operand in ipairs(operandSpec) do
    if instruction[operand] == nil then
      fail({ field = field .. "." .. operand, op = op })
    end
  end
  if op == "compare" then
    if not COMPARE_CONDITIONS[instruction.condition] then
      fail({ field = field .. ".condition" })
    end
    if not isIntegerInRange(instruction.var, 0, VARIABLE_MAX) or not isValidOperand(instruction.amount, false) then
      fail({ field = field .. ".compare" })
    end
  elseif op == "note" then
    if
      not isKey(instruction.key)
      or not isIntegerInRange(instruction.velocity, 0, 0x7F)
      or not isValidOperand(instruction.duration, true)
    then
      fail({ field = field .. ".note" })
    end
  elseif op == "wait" then
    if not isValidOperand(instruction.duration, true) then
      fail({ field = field .. ".duration" })
    end
  elseif op == "program" then
    if not isValidOperand(instruction.program, true) then
      fail({ field = field .. ".program" })
    end
  elseif op == "open_track" then
    if not isIntegerInRange(instruction.track, 0, TRACK_MAX) or not isTarget(instruction.target, instructionCount) then
      fail({ field = field .. ".target" })
    end
  elseif op == "jump" or op == "call" then
    if not isTarget(instruction.target, instructionCount) then
      fail({ field = field .. ".target" })
    end
  elseif op == "loop_begin" then
    if not isValidOperand(instruction.count, true) then
      fail({ field = field .. ".count" })
    end
  elseif operandSpec[1] == "var" then
    if not isIntegerInRange(instruction.var, 0, VARIABLE_MAX) or not isValidOperand(instruction.amount, false) then
      fail({ field = field .. ".operand" })
    end
  elseif operandSpec[1] == "amount" and not isValidOperand(instruction.amount, false) then
    fail({ field = field .. ".amount" })
  end
end

function AudioSequence.validate(sequence)
  if type(sequence) ~= "table" then
    fail({})
  end
  if sequence.schema ~= AudioSequence.SCHEMA then
    fail({ field = "schema" })
  end
  if not Validate.isNonNegativeInteger(sequence.id) then
    fail({ field = "id" })
  end
  if sequence.symbol ~= nil and (type(sequence.symbol) ~= "string" or sequence.symbol == "") then
    fail({ field = "symbol" })
  end
  if not isIntegerInRange(sequence.bankId, 0, 0xFFFF) then
    fail({ field = "bankId" })
  end
  local player = sequence.player
  if type(player) ~= "table" then
    fail({ field = "player" })
  end
  assertOnlyKeys(player, { id = true, initialVolume = true, playerPriority = true, channelPriority = true }, "player")
  if not isIntegerInRange(player.id, 0, 31) then
    fail({ field = "player.id" })
  end
  if not isIntegerInRange(player.initialVolume, 0, 0x7F) then
    fail({ field = "player.initialVolume" })
  end
  if not isIntegerInRange(player.playerPriority, 0, 0xFF) then
    fail({ field = "player.playerPriority" })
  end
  if not isIntegerInRange(player.channelPriority, 0, 0xFF) then
    fail({ field = "player.channelPriority" })
  end
  local program = sequence.program
  if type(program) ~= "table" then
    fail({ field = "program" })
  end
  assertOnlyKeys(program, { entry = true, initialTrackMask = true, instructions = true }, "program")
  if not isIntegerInRange(program.initialTrackMask, 1, 0xFFFF) or program.initialTrackMask % 2 ~= 1 then
    fail({ field = "program.initialTrackMask" })
  end
  if not Validate.isArray(program.instructions) or #program.instructions == 0 then
    fail({ field = "program.instructions" })
  end
  if not isTarget(program.entry, #program.instructions) then
    fail({ field = "program.entry" })
  end
  for index, instruction in ipairs(program.instructions) do
    if type(instruction) ~= "table" or type(instruction.op) ~= "string" then
      fail({ field = "program.instructions[" .. index .. "].op" })
    end
    local op = instruction.op
    local operandSpec = OPS[op]
    if operandSpec == nil then
      fail({ field = "program.instructions[" .. index .. "].op", op = op })
    end
    operandSpec = operandSpec --[[@as table]]
    -- Exact instruction shapes: the record carries its op and exactly its
    -- Conditional execution owns a complete nested instruction so variable-
    -- length source commands cannot be split by the runtime.
    local allowed = { op = true }
    for _, operand in ipairs(operandSpec) do
      allowed[operand] = true
    end
    assertOnlyKeys(instruction, allowed, "program.instructions[" .. index .. "]")
    for _, operand in ipairs(operandSpec) do
      if instruction[operand] == nil then
        fail({ field = "program.instructions[" .. index .. "]." .. operand, op = op })
      end
    end
    if op == "if" then
      if instruction.condition ~= "compare_result" then
        fail({ field = "program.instructions[" .. index .. "].condition" })
      end
      validateNestedInstruction(
        instruction.instruction,
        "program.instructions[" .. index .. "].instruction",
        #program.instructions
      )
    elseif op == "compare" then
      if
        not COMPARE_CONDITIONS[instruction.condition]
        or not isIntegerInRange(instruction.var, 0, VARIABLE_MAX)
        or not isValidOperand(instruction.amount, false)
      then
        fail({ field = "program.instructions[" .. index .. "].compare" })
      end
    elseif op == "note" then
      if not isKey(instruction.key) then
        fail({ field = "program.instructions[" .. index .. "].key" })
      end
      if not isIntegerInRange(instruction.velocity, 0, 0x7F) then
        fail({ field = "program.instructions[" .. index .. "].velocity" })
      end
      if not isValidOperand(instruction.duration, true) then
        fail({ field = "program.instructions[" .. index .. "].duration" })
      end
    elseif op == "wait" then
      if not isValidOperand(instruction.duration, true) then
        fail({ field = "program.instructions[" .. index .. "].duration" })
      end
    elseif op == "program" then
      if not isValidOperand(instruction.program, true) then
        fail({ field = "program.instructions[" .. index .. "].program" })
      end
    elseif op == "open_track" then
      if not isIntegerInRange(instruction.track, 0, TRACK_MAX) then
        fail({ field = "program.instructions[" .. index .. "].track" })
      end
      if not isTarget(instruction.target, #program.instructions) then
        fail({ field = "program.instructions[" .. index .. "].target" })
      end
    elseif op == "jump" or op == "call" then
      if not isTarget(instruction.target, #program.instructions) then
        fail({ field = "program.instructions[" .. index .. "].target" })
      end
    elseif op == "loop_begin" then
      if not isValidOperand(instruction.count, true) then
        fail({ field = "program.instructions[" .. index .. "].count" })
      end
    elseif operandSpec[1] == "var" then
      if not isIntegerInRange(instruction.var, 0, VARIABLE_MAX) then
        fail({ field = "program.instructions[" .. index .. "].var" })
      end
      if not isValidOperand(instruction.amount, false) then
        fail({ field = "program.instructions[" .. index .. "].amount" })
      end
    elseif operandSpec[1] == "amount" then
      if not isValidOperand(instruction.amount, false) then
        fail({ field = "program.instructions[" .. index .. "].amount" })
      end
    end
  end
  if sequence.provenance ~= nil and type(sequence.provenance) ~= "table" then
    fail({ field = "provenance" })
  end
  return true
end

return AudioSequence
