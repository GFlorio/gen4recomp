-- Source field-weather commands lower to existing semantic state operations.

local Assert = require("tests.support.Assert")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")

local T = {}

local function lower(instructions)
  local script = { instructions = instructions }
  local member = { scripts = {}, movements = {} }
  return SemanticLowering.lowerScript(script, member, { stdCatalog = {} }).items
end

local function instruction(opcode, offset, operands)
  return { opcode = opcode, offset = offset, operands = operands or {} }
end

local function raw(value)
  return { raw = value }
end

function T.flash_action_modes_use_the_existing_flag_vocabulary()
  local set = lower({ instruction(401, 0x10, { raw(1) }) })[1]
  local clear = lower({ instruction(401, 0x20, { raw(0) }) })[1]
  local check = lower({ instruction(401, 0x30, { raw(2), raw(0x8001) }) })[1]

  Assert.deepEqual(
    set,
    { op = "set_flag", flag = "FLAG_SYS_FLASH", provenance = { offsets = { 0x10 }, opcodes = { 401 } } }
  )
  Assert.deepEqual(
    clear,
    { op = "clear_flag", flag = "FLAG_SYS_FLASH", provenance = { offsets = { 0x20 }, opcodes = { 401 } } }
  )
  Assert.equal(check.op, "set_var")
  Assert.deepEqual(check.variable, { value = "var", id = 0x8001 })
  Assert.deepEqual(check.value, { value = "flag_value", flag = "FLAG_SYS_FLASH" })
end

function T.defog_action_modes_use_the_existing_flag_vocabulary()
  local set = lower({ instruction(402, 0x40, { raw(1) }) })[1]
  local check = lower({ instruction(402, 0x50, { raw(2), raw(0x8002) }) })[1]

  Assert.equal(set.op, "set_flag")
  Assert.equal(set.flag, "FLAG_SYS_DEFOG")
  Assert.equal(check.op, "set_var")
  Assert.deepEqual(check.variable, { value = "var", id = 0x8002 })
  Assert.deepEqual(check.value, { value = "flag_value", flag = "FLAG_SYS_DEFOG" })
end

function T.flash_effect_lowers_to_effect_then_unprovenanced_yield()
  local steps = lower({ instruction(181, 0x60) })
  Assert.equal(#steps, 2)
  Assert.deepEqual(steps[1].provenance, { offsets = { 0x60 }, opcodes = { 181 } })
  Assert.equal(steps[1].op, "change_weather")
  Assert.equal(steps[1].weatherId, 12)
  Assert.deepEqual(steps[2], { op = "yield_tick" })
end

function T.unknown_flag_action_mode_is_rejected()
  local ok, err = pcall(function()
    lower({ instruction(401, 0x70, { raw(9) }) })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("action mode", 1, true) ~= nil)
end

return { tests = T }
