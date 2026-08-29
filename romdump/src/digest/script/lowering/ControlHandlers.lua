-- Script lowering handlers for control flow, state, and core source operations.
local Operands = require("romdump.src.digest.script.lowering.Operands")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local function nop()
  return nil
end -- Nop

local function dummy()
  return nil
end -- Dummy

local function stop()
  return { op = "stop" }
end

local function wait(ins, _, _, _)
  -- Wait frames, var: every Wait mirrors the countdown into its
  -- destination variable exactly like the source engine (ScrCmd_Wait
  -- writes the frame count at execution; RunPauseTimer decrements the
  -- variable itself per poll and completes at zero). Nothing is ever
  -- discarded, so observable reads and cross-context reads see the live
  -- countdown. A Wait without a variable operand stays internal to the
  -- task state.
  local step = {
    op = "wait_ticks",
    ticks = Operands.operandValue(ins.operands[1]),
  }
  local countdown = Operands.varRef(ins.operands[2])
  if type(countdown) == "table" then
    step.countdownVariable = countdown
  end
  return step
end

local function compareVars(ins)
  return { op = "compare", left = Operands.varRef(ins.operands[1]), right = Operands.varRef(ins.operands[2]) }
end

local function compareVarsAlt(ins)
  return { op = "compare", left = Operands.varRef(ins.operands[1]), right = Operands.varRef(ins.operands[2]) }
end

local function callStandard(ins, _, _, ctx)
  -- CallStd id: resolve the std catalog to the public `common.<name>` id
  -- (decomp symbols and binary numeric ids both resolve); unknown ids stay
  -- mechanical `common.std_<id>`.
  local id = Operands.operandValue(ins.operands[1])
  local target
  if ctx.stdCatalog ~= nil then
    target = SourceCatalog.commonPublicId(ctx.stdCatalog, id)
  else
    target = "common.std_" .. tostring(id)
  end
  return { op = "call_common", target = target }
end

local function signalCaller()
  return { op = "signal_caller" }
end

local function gotoLabel(ins)
  return { op = "goto", target = Operands.operandValue(ins.operands[1]) }
end

local function objectGoto(ins)
  return {
    op = "goto_if",
    condition = {
      condition = "compare",
      operator = "eq",
      left = { value = "object_id", ref = { ref = "actor", special = "self" } },
      right = Operands.operandValue(ins.operands[1]),
    },
    target = Operands.operandValue(ins.operands[2]),
  }
end

local function backgroundGoto(ins)
  return {
    op = "goto_if",
    condition = {
      condition = "compare",
      operator = "eq",
      left = { value = "trigger_background_id" },
      right = Operands.operandValue(ins.operands[1]),
    },
    target = Operands.operandValue(ins.operands[2]),
  }
end

local function directionGoto(ins)
  return {
    op = "goto_if",
    condition = {
      condition = "compare",
      operator = "eq",
      left = { value = "trigger_direction" },
      right = Operands.operandValue(ins.operands[1]),
    },
    target = Operands.operandValue(ins.operands[2]),
  }
end

local function callLabel(ins)
  return { op = "call", target = Operands.operandValue(ins.operands[1]) }
end

local function returnFromScript()
  return { op = "return" }
end

local function gotoIf()
  return "unfolded"
end -- folded with the compare/flag

local function callIf()
  return "unfolded"
end -- folded with the compare/flag

local function setFlag(ins)
  return { op = "set_flag", flag = Operands.operandValue(ins.operands[1]) }
end

local function clearFlag(ins)
  return { op = "clear_flag", flag = Operands.operandValue(ins.operands[1]) }
end

local function checkFlag()
  return "unfolded"
end -- folded with GoToIfSet/Unset

local function setFlagVar(ins)
  return { op = "set_flag", flag = Operands.varRef(ins.operands[1]) }
end

local function clearFlagVar(ins)
  return { op = "clear_flag", flag = Operands.varRef(ins.operands[1]) }
end

local function setVarFromFlag(ins)
  return {
    op = "set_var",
    variable = Operands.varRef(ins.operands[2]),
    value = { value = "flag_value", flag = Operands.varRef(ins.operands[1]) },
  }
end

local function addVar(ins)
  return { op = "add_var", variable = Operands.varRef(ins.operands[1]), amount = Operands.varRef(ins.operands[2]) }
end

local function subtractVar(ins)
  return { op = "sub_var", variable = Operands.varRef(ins.operands[1]), amount = Operands.varRef(ins.operands[2]) }
end

local function setVar(ins)
  return { op = "set_var", variable = Operands.varRef(ins.operands[1]), value = Operands.operandValue(ins.operands[2]) }
end

local function copyVar(ins)
  return {
    op = "copy_var",
    destination = Operands.varRef(ins.operands[1]),
    source = Operands.varRef(ins.operands[2]),
  }
end

local function setVarFromVar(ins)
  return { op = "set_var", variable = Operands.varRef(ins.operands[1]), value = Operands.varRef(ins.operands[2]) }
end

local function setSpawn(ins)
  return { op = "set_spawn", spawn = Operands.operandValue(ins.operands[1]) }
end

local function setPlayerGender(ins)
  return { op = "set_var", variable = Operands.varRef(ins.operands[1]), value = { value = "player_gender_value" } }
end

local function random(ins)
  -- Random arg0, arg1: arg0 is the destination variable pointer and arg1
  -- is the modulo source (ScrCmd_Random reads the dest first).
  return {
    op = "random",
    result = Operands.varRef(ins.operands[1]),
    maxExclusive = Operands.operandValue(ins.operands[2]),
  }
end

local function getPlayerFacing(ins)
  return { op = "get_player_facing", result = Operands.varRef(ins.operands[1]) }
end

return {
  [0] = nop,
  [1] = dummy,
  [2] = stop,
  [3] = wait,
  [17] = compareVars,
  [18] = compareVarsAlt,
  [20] = callStandard,
  [21] = signalCaller,
  [22] = gotoLabel,
  [23] = objectGoto,
  [24] = backgroundGoto,
  [25] = directionGoto,
  [26] = callLabel,
  [27] = returnFromScript,
  [28] = gotoIf,
  [29] = callIf,
  [30] = setFlag,
  [31] = clearFlag,
  [32] = checkFlag,
  [33] = setFlagVar,
  [34] = clearFlagVar,
  [35] = setVarFromFlag,
  [39] = addVar,
  [40] = subtractVar,
  [41] = setVar,
  [42] = copyVar,
  [43] = setVarFromVar,
  [280] = setSpawn,
  [281] = setPlayerGender,
  [380] = random,
  [386] = getPlayerFacing,
}
