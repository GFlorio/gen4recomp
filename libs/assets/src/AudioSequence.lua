-- Validator for the derived audio sequence asset: numeric and symbolic
-- identity, a bank reference, a player block, and a program whose branch
-- targets are instruction indices, never source offsets. Packed SSEQ operand
-- encodings are normalized: amounts are plain integers or
-- {kind=random min max} / {kind=variable} records. The instruction
-- vocabulary itself is not closed here: the semantic name set is frozen with
-- the opcode inventory, so validation is structural (every instruction has a
-- non-empty semantic op; note/rest/program/jump/call/loop_begin carry their
-- required fields; any instruction's duration/amount/target fields must be
-- well formed). Source provenance may ride along for diagnostics but is
-- never behavior-visible.

local AudioSequence = {}

local Validate = require("libs.assets.src.Validate")
local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")

AudioSequence.SCHEMA = Contract.audio.sequenceSchema

local function fail(context)
  Errors.raise("AUDIO_SEQUENCE_INVALID", "malformed audio sequence asset", context)
end

local function isIntegerInRange(value, low, high)
  return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

local function isDuration(value)
  return isIntegerInRange(value, 0, 0xFFFF)
end

local function isKey(value)
  return isIntegerInRange(value, 0, 0x7F)
end

local function isTarget(value, count)
  return isIntegerInRange(value, 1, count)
end

local function isValidAmount(amount)
  if type(amount) == "number" then
    -- Plain amounts are normalized integers, never fractions.
    return amount % 1 == 0
  end
  if type(amount) ~= "table" then
    return false
  end
  if amount.kind == "variable" then
    return true
  end
  if amount.kind == "random" then
    return isIntegerInRange(amount.min, -0x8000, 0x7FFF)
      and isIntegerInRange(amount.max, -0x8000, 0x7FFF)
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
    if type(instruction) ~= "table" or type(instruction.op) ~= "string" or instruction.op == "" then
      fail({ field = "program.instructions[" .. index .. "].op" })
    end
    local op = instruction.op
    if op == "note" then
      if not isKey(instruction.key) then
        fail({ field = "program.instructions[" .. index .. "].key" })
      end
      if not isIntegerInRange(instruction.velocity, 0, 0x7F) then
        fail({ field = "program.instructions[" .. index .. "].velocity" })
      end
      if not isDuration(instruction.duration) then
        fail({ field = "program.instructions[" .. index .. "].duration" })
      end
    elseif op == "rest" then
      if not isDuration(instruction.duration) then
        fail({ field = "program.instructions[" .. index .. "].duration" })
      end
    elseif op == "program" then
      if not isIntegerInRange(instruction.program, 0, 0xFFFF) then
        fail({ field = "program.instructions[" .. index .. "].program" })
      end
    elseif op == "jump" or op == "call" then
      if not isTarget(instruction.target, #program.instructions) then
        fail({ field = "program.instructions[" .. index .. "].target" })
      end
    elseif op == "loop_begin" then
      if not isIntegerInRange(instruction.count, 0, 0xFFFF) then
        fail({ field = "program.instructions[" .. index .. "].count" })
      end
    end
    if instruction.amount ~= nil and not isValidAmount(instruction.amount) then
      fail({ field = "program.instructions[" .. index .. "].amount" })
    end
    if instruction.duration ~= nil and not isDuration(instruction.duration) then
      fail({ field = "program.instructions[" .. index .. "].duration" })
    end
    if instruction.target ~= nil and not isTarget(instruction.target, #program.instructions) then
      fail({ field = "program.instructions[" .. index .. "].target" })
    end
  end
  if sequence.provenance ~= nil and type(sequence.provenance) ~= "table" then
    fail({ field = "provenance" })
  end
  return true
end

return AudioSequence
