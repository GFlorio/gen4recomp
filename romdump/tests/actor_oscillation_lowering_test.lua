-- Actor oscillation source lowering: ScrCmd_523 operand normalization.
-- Pinned retail oracle: pret/pokeheartgold src/scrcmd_c.c (ScrCmd_523 obtains
-- its five operands then starts the oscillation task) and asm/unk_0205BB1C.s
-- (sub_0205BED8 presentation-vector motion) at 0985e8718df4f25e64d6507d89c0c97c0d288981.
-- Raw source amplitudes are HGSS displacement units; the producer normalizes
-- proven literal forms by dividing by 16 before semantic IR is produced.

local Assert = require("tests.support.Assert")
local FieldHandlers = require("romdump.src.digest.script.lowering.FieldHandlers")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")

local T = {}

local function raw(value)
  return { raw = value }
end

local function instruction(opcode, offset, operands)
  return { opcode = opcode, offset = offset, operands = operands }
end

local function lower(instructions)
  local script = { instructions = instructions }
  local member = { scripts = {}, movements = {} }
  return SemanticLowering.lowerScript(script, member, { stdCatalog = {} })
end

local function hasOp(items, op)
  for _, item in ipairs(items) do
    if item.op == op then
      return true
    end
  end
  return false
end

function T.retail_literal_amplitudes_normalize_to_world_displacement()
  local ins = instruction(523, 0x20, { raw(3), raw(2), raw(90), raw(2), raw(3) })
  local handler = assert(FieldHandlers[523], "handler 523 must exist")
  local node = handler(ins)
  Assert.equal(node.op, "actor_oscillate")
  Assert.near(node.amplitudeX, 0.125, 1e-9)
  Assert.near(node.amplitudeZ, 0.1875, 1e-9)
  Assert.equal(node.cycles, 2)
  Assert.equal(node.degreesPerTick, 90)
  Assert.isNil(node.sourceScale, "no source scale rides the semantic node")

  local lowered = lower({ instruction(523, 0x20, { raw(3), raw(2), raw(90), raw(2), raw(3) }) })
  Assert.equal(#lowered.items, 1)
  local item = lowered.items[1]
  Assert.equal(item.op, "actor_oscillate")
  Assert.near(item.amplitudeX, 0.125, 1e-9)
  Assert.near(item.amplitudeZ, 0.1875, 1e-9)
  Assert.equal(item.cycles, 2)
  Assert.equal(item.degreesPerTick, 90)
  Assert.deepEqual(item.provenance, { offsets = { 0x20 }, opcodes = { 523 } })
  Assert.equal(#lowered.unsupported, 0)
end

function T.cycles_and_degrees_stay_referencable_while_literal_amplitudes_normalize()
  local lowered = lower({ instruction(523, 0x30, { raw(3), raw(0x4000), raw(0x4001), raw(2), raw(0) }) })
  Assert.equal(#lowered.items, 1)
  local item = lowered.items[1]
  Assert.equal(item.op, "actor_oscillate")
  Assert.deepEqual(item.cycles, { value = "var", id = 0x4000 })
  Assert.deepEqual(item.degreesPerTick, { value = "var", id = 0x4001 })
  Assert.near(item.amplitudeX, 0.125, 1e-9)
  Assert.equal(item.amplitudeZ, 0)
  Assert.equal(#lowered.unsupported, 0)
end

function T.variable_amplitude_source_form_lowers_to_accounted_unsupported()
  local lowered = lower({ instruction(523, 0x20, { raw(3), raw(2), raw(90), raw(0x4002), raw(0) }) })
  Assert.equal(#lowered.items, 1)
  local item = lowered.items[1]
  Assert.equal(item.op, "unsupported")
  Assert.equal(item.command, 523)
  Assert.equal(item.sourceOffset, 0x20)
  Assert.deepEqual(item.arguments, { 3, 2, 90, 0x4002, 0 })
  Assert.isTrue(
    type(item.reason) == "string" and item.reason:find("mplitude") ~= nil,
    "reason names the amplitude form"
  )
  Assert.deepEqual(item.provenance, { offsets = { 0x20 }, opcodes = { 523 } })
  Assert.isFalse(hasOp(lowered.items, "actor_oscillate"), "no supported oscillation is emitted")
  Assert.equal(#lowered.unsupported, 1)
  Assert.isTrue(lowered.unsupported[1] == item, "the same step is recorded once in unsupported")
end

return { tests = T }
