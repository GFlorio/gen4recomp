-- Validator for the derived audio sequence asset: numeric and symbolic
-- identity, a bank reference, a player block, and a program whose branch
-- targets are instruction indices, never source offsets. The instruction
-- vocabulary is closed: every emitted op is a member of the frozen semantic
-- set (the lowering emits nothing else), each op requires exactly its
-- operand(s), and every operand is normalized to a plain integer,
-- {kind=random min max}, or {kind=variable var}. Source value ranges survive
-- (durations and program numbers are not truncated to u16), so the validator
-- rejects only impossible shapes: unknown or deleted ops, missing or
-- illegally shaped operands, variables without a valid variable number
-- (0..31: 16 player-local plus 16 global SDK variables), track numbers
-- outside 0..15, out-of-range branch targets, note key/velocity outside
-- 0..127, and non-boolean conditionals. Source provenance may ride along for
-- diagnostics but is never behavior-visible.

local AudioSequence = {}

local Validate = require("libs.assets.src.Validate")
local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.assets.src.AudioErrors")
local Contract = require("libs.assets.src.DerivedAssetContract")

AudioSequence.SCHEMA = Contract.audio.sequenceSchema

-- The closed semantic operation vocabulary shared by the lowering and the
-- player. `rest` and `print_var` are deliberately absent: no producer emits
-- a semantic rest (SSEQ WAIT models the behavior), and print_var is an NNS
-- diagnostic dropped during lowering.
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
  cmp_eq = { "var", "amount" },
  cmp_ge = { "var", "amount" },
  cmp_gt = { "var", "amount" },
  cmp_le = { "var", "amount" },
  cmp_lt = { "var", "amount" },
  cmp_ne = { "var", "amount" },
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

local function fail(context)
  Errors.raise(AudioErrors.AUDIO_SEQUENCE_INVALID, "malformed audio sequence asset", context)
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

-- A normalized operand: a plain integer, a random {min, max} pair (any
-- ordered integer pair: the source spans the full signed range, never a
-- truncated u16), or a variable {var} record with a valid variable number.
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
    return isIntegerInRange(amount.var, 0, VARIABLE_MAX)
  end
  if amount.kind == "random" then
    return type(amount.min) == "number"
      and amount.min % 1 == 0
      and type(amount.max) == "number"
      and amount.max % 1 == 0
      and amount.min <= amount.max
  end
  return false
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
  if not isIntegerInRange(player.id, 0, 0xFF) then
    fail({ field = "player.id" })
  end
  if not isIntegerInRange(player.initialVolume, 0, 0xFF) then
    fail({ field = "player.initialVolume" })
  end
  if not isIntegerInRange(player.channelPriority, 0, 0xFF) then
    fail({ field = "player.channelPriority" })
  end
  if not isIntegerInRange(player.playerPriority, 0, 0xFF) then
    fail({ field = "player.playerPriority" })
  end
  local program = sequence.program
  if type(program) ~= "table" then
    fail({ field = "program" })
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
    if instruction.conditional ~= nil and type(instruction.conditional) ~= "boolean" then
      fail({ field = "program.instructions[" .. index .. "].conditional" })
    end
    for _, operand in ipairs(operandSpec) do
      if instruction[operand] == nil then
        fail({ field = "program.instructions[" .. index .. "]." .. operand, op = op })
      end
    end
    if op == "note" then
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
