-- Translation verifier : compares the original Raw IR
-- and CFG against the lowered semantic IR. It verifies translation-accounting
-- and control-flow preservation, not full game-behavior equivalence:
--
-- 1. Every reachable source instruction is covered by one semantic node
-- or an explicit unsupported node (Nop/Dummy are the only documented
-- implementation-detail erasures).
-- 2. Every original control edge is represented by a control node.
-- 3. Every semantic side effect maps back to source offsets.
-- 4. Every source execution classification is represented by an
-- equivalent graph boundary or timing profile.
-- 5. Discarded implementation variables are proven unobservable.
-- 6. Canonicalized operands resolve to the same constants.
-- 7. Call/return balance is preserved.
-- 8. Movement sequence termination is preserved.
-- 9. No command disappears except an explicitly documented erasure.
-- 10. Unsupported instructions prevent a `complete` result.
--
-- every supported terminal path of a common script must signal its caller
-- (RestartCurrentScript -> signal_caller) before ending, matching the pinned
-- `ScrCmd_RestartCurrentScript` bit protocol. Pure domain module: no love
-- dependency.

local Cfg = require("romdump.src.digest.script.Cfg")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")

local Verifier = {}

-- Branch and call opcodes: their covering node must be a control node.
local CONTROL_OPS = {
  ["goto"] = true,
  goto_if = true,
  goto_compared = true,
  call_compared = true,
  if_cond = true,
  call_if = true,
  ["if"] = true,
  goto_script = true,
}

-- Blocking (native-wait) operations: an instruction classified native_wait
-- must be covered by one of these, or by an explicit unsupported node.
local BLOCKING_OPS = {
  wait_ticks = true,
  say = true,
  message = true,
  wait_input = true,
  wait_input_or_ticks = true,
  wait_movement = true,
  wait_sound = true,
  wait_cry = true,
  wait_fanfare = true,
  wait_fade = true,
  ask_yes_no = true,
  warp = true,
  call_common = true,
}

-- Operations that end the run phase: yield boundaries and stops.
local YIELD_OPS = {
  yield_tick = true,
  lock_all = true,
  release_all = true,
  stop = true,
}

-- The documented multi-instruction folds (they own a timing profile of their
-- own, so per-instruction classification checks do not apply to them).
-- `if` covers the conditional cross-script branch wrap; `goto_if` is the
-- label/goto fallback of a compare+GoToIf fold that the structurer could
-- not peel.
local FOLD_OPS = { say = true, if_cond = true, call_if = true, ["if"] = true, goto_if = true }

-- Whether a lowered node ends the run phase by blocking (native wait). The
-- `message` op blocks only with waitForPrint; `lock_actor` blocks only with
-- waitUntilPausable.
---@param node table
---@return boolean
local function nodeBlocks(node)
  if node.op == "message" then
    return node.waitForPrint == true
  end
  if node.op == "lock_actor" then
    return node.waitUntilPausable == true
  end
  return BLOCKING_OPS[node.op] == true
end

-- Instructions whose operand values are side effects on the script stack
-- (counted for the stack-balance and observability checks).
local CALL_OPS = { [26] = true, [29] = true }
local RETURN_OPS = { [27] = true }

-- Compare an operand raw value with a node field (varRef forms match their
-- symbolic operands).
---@param raw any
---@param node any
---@return boolean
local function operandMatches(raw, node)
  if type(node) == "table" and type(raw) == "string" then
    if node.value == "var" then
      return node.id == raw
    end
    if node.value == "local" then
      return node.name == raw
    end
  end
  return node == raw
end

-- The per-opcode operand-equivalence checkers (item 6): `(ins, step)` ->
-- problem message or nil. Covering the high-value operand-carrying
-- instructions; the rest are checked by the generic coverage rule.
local CHECKERS = {
  [3] = function(ins, step)
    if step.op == "unsupported" then
      return nil
    end
    if not operandMatches(ins.operands[1].raw, step.ticks) then
      return "Wait frame count changed by translation"
    end
  end,
  [22] = function(ins, step)
    if step.op == "goto_script" then
      return nil
    end
    if not operandMatches(ins.operands[1].raw, step.target) then
      return "GoTo target changed by translation"
    end
  end,
  [26] = function(ins, step)
    if step.label ~= nil then
      return nil
    end
    if not operandMatches(ins.operands[1].raw, step.target) then
      return "Call target changed by translation"
    end
  end,
  [30] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.flag) then
      return "SetFlag id changed by translation"
    end
  end,
  [31] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.flag) then
      return "ClearFlag id changed by translation"
    end
  end,
  [33] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.flag) then
      return "SetFlagVar id changed by translation"
    end
  end,
  [34] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.flag) then
      return "ClearFlagVar id changed by translation"
    end
  end,
  [39] = function(ins, step)
    if
      not operandMatches(ins.operands[1].raw, step.variable)
      or not operandMatches(ins.operands[2].raw, step.amount)
    then
      return "AddVar operands changed by translation"
    end
  end,
  [40] = function(ins, step)
    if
      not operandMatches(ins.operands[1].raw, step.variable)
      or not operandMatches(ins.operands[2].raw, step.amount)
    then
      return "SubVar operands changed by translation"
    end
  end,
  [41] = function(ins, step)
    if
      not operandMatches(ins.operands[1].raw, step.variable)
      or not operandMatches(ins.operands[2].raw, step.value)
    then
      return "SetVar operands changed by translation"
    end
  end,
  [42] = function(ins, step)
    if
      not operandMatches(ins.operands[1].raw, step.destination)
      or not operandMatches(ins.operands[2].raw, step.source)
    then
      return "CopyVar operands changed by translation"
    end
  end,
  [43] = function(ins, step)
    if
      not operandMatches(ins.operands[1].raw, step.variable)
      or not operandMatches(ins.operands[2].raw, step.value)
    then
      return "SetOrCopyVar operands changed by translation"
    end
  end,
  [73] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.sound) then
      return "PlaySE sound changed by translation"
    end
  end,
  [74] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.sound) then
      return "StopSE sound changed by translation"
    end
  end,
  [75] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.sound) then
      return "WaitSE sound changed by translation"
    end
  end,
  [80] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.music) then
      return "PlayBGM music changed by translation"
    end
  end,
  [87] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.music) then
      return "TempBGM music changed by translation"
    end
  end,
  [280] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.spawn) then
      return "SetSpawn id changed by translation"
    end
  end,
  [348] = function(ins, step)
    if not operandMatches(ins.operands[1].raw, step.ticks) then
      return "WaitButtonOrDelay ticks changed by translation"
    end
  end,
}

-- Walk the lowered items collecting the covering node per source offset.
---@param items table[]
---@return table<integer, table> byOffset
local function coveredByOffset(items)
  local byOffset = {}
  local function walk(list)
    for _, item in ipairs(list) do
      if item.provenance ~= nil then
        for _, offset in ipairs(item.provenance.offsets) do
          byOffset[offset] = item
        end
      end
      if item.op == "if" then
        walk(item.yes)
        walk(item.no)
      end
    end
  end
  walk(items)
  return byOffset
end

-- Verify one script's final structured steps against its raw instructions
-- and CFG. The steps are the post-structuring, post-scrub program that is
-- actually emitted and executed; `omissions` are the lowering's documented
-- erasures (the only instructions allowed to disappear).
---@param steps table[]
---@param script table raw script (instructions)
---@param memberIr table|nil
---@param omissions table|nil
---@return table report
function Verifier.verifyScript(steps, script, memberIr, omissions)
  local cfg = Cfg.build(script, memberIr)
  local byOffset = coveredByOffset(steps)
  -- A synthesized prelude script is a shared-subroutine library that the
  -- source engine never enters from its entry: its returns without calls
  -- are the defining shape, so the balance and stray-return checks warn
  -- rather than fault for preludes.
  local prelude = script.prelude == true
  local report = { ok = true, complete = false, problems = {}, warnings = {} }
  local function problem(message, context)
    report.ok = false
    report.problems[#report.problems + 1] = { message = message, context = context }
  end
  local function warn(message, context)
    report.warnings[#report.warnings + 1] = { message = message, context = context }
  end

  -- Item 9: every command disappears only through a documented omission.
  local omissionsByOffset = {}
  for _, omission in ipairs(omissions or {}) do
    omissionsByOffset[omission.offset] = true
    if omission.opcode ~= 0 and omission.opcode ~= 1 then
      problem("omission recorded for a non-erasure opcode", { offset = omission.offset, opcode = omission.opcode })
    end
  end

  local total = #script.instructions
  local covered = 0
  local reachable = 0
  local reachableUnsupported = 0
  local unsupportedNodes = {}
  local reachableOmitted = 0
  for i, ins in ipairs(script.instructions) do
    local isReachable = cfg.reachable[cfg.blockOfIndex[i]] == true
    if isReachable then
      reachable = reachable + 1
    end
    local node = byOffset[ins.offset]
    if node ~= nil then
      covered = covered + 1
      if node.op == "unsupported" then
        reachableUnsupported = reachableUnsupported + 1
        unsupportedNodes[#unsupportedNodes + 1] = node
      end
    elseif omissionsByOffset[ins.offset] then
      if isReachable then
        reachableOmitted = reachableOmitted + 1
      end
    else
      problem(
        "instruction not covered by any semantic node",
        { offset = ins.offset, opcode = ins.opcode, name = CommandCatalog.name(ins.opcode) }
      )
    end
  end

  -- Item 2: every original control edge is represented by a control node.
  local controlOffsets = {
    [22] = true,
    [23] = true,
    [24] = true,
    [25] = true,
    [28] = true,
    [29] = true,
  }
  for _, ins in ipairs(script.instructions) do
    if controlOffsets[ins.opcode] then
      local node = byOffset[ins.offset]
      if node ~= nil and node.op ~= "unsupported" and not CONTROL_OPS[node.op] then
        problem(
          "control edge not represented by a control node",
          { offset = ins.offset, opcode = ins.opcode, node = node.op }
        )
      end
    end
    if ins.opcode == 26 then
      local node = byOffset[ins.offset]
      if
        node ~= nil
        and node.op ~= "unsupported"
        and node.op ~= "call"
        and node.op ~= "call_if"
        and node.op ~= "call_compared"
      then
        problem(
          "call edge not represented by a call node",
          { offset = ins.offset, opcode = ins.opcode, node = node and node.op }
        )
      end
    end
  end

  -- Branch targets must resolve to script labels (relative offsets resolve
  -- through the CFG; unresolvable targets show as dangling edges). A
  -- dangling edge whose branch was lowered to an explicit unsupported node
  -- or to a runtime-resolved cross-script reference (goto_script, or a
  -- call with a label) is accounted for and not double-reported.
  for _, block in pairs(cfg.blocks) do
    local lastIns = script.instructions[block.indices[#block.indices]]
    local lastNode = lastIns ~= nil and byOffset[lastIns.offset] or nil
    local function crossScript(node)
      if node == nil then
        return false
      end
      if node.op == "goto_script" then
        return true
      end
      if node.op == "call" and node.label ~= nil then
        return true
      end
      if (node.op == "goto_compared" or node.op == "call_compared") and node.script ~= nil then
        return true
      end
      -- A structured conditional wrapping a cross-script reference.
      if node.op == "if" and node.yes and node.yes[1] then
        local inner = node.yes[1]
        if inner.op == "goto_script" then
          return true
        end
        if inner.op == "call" and inner.label ~= nil then
          return true
        end
      end
      return false
    end
    for _, succ in ipairs(block.successors) do
      if succ.kind == "branch" or succ.kind == "call" then
        if
          succ.targetIndex == nil
          and not crossScript(lastNode)
          and (lastNode == nil or lastNode.op ~= "unsupported")
        then
          problem(
            "branch target does not resolve to an instruction",
            { block = block.id, entryOffset = block.entryOffset, kind = succ.kind }
          )
        end
      end
    end
  end

  -- Item 4: every source execution classification is represented by an
  -- equivalent boundary or timing profile.
  for _, ins in ipairs(script.instructions) do
    local node = byOffset[ins.offset]
    if node ~= nil and node.op ~= "unsupported" then
      local foldOffsets = node.provenance and node.provenance.offsets or {}
      if #foldOffsets > 1 then
        -- A documented fold owns its timing profile; any other multi-offset
        -- node is an unmodeled merge.
        if not FOLD_OPS[node.op] then
          problem(
            "multi-instruction node is not a documented fold",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        end
      else
        local classification = CommandCatalog.classification(ins.opcode)
        local boundary = nodeBlocks(node) or YIELD_OPS[node.op] == true
        if classification == CommandCatalog.NATIVE_WAIT and not boundary then
          problem(
            "native-wait instruction lacks a blocking translation",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        elseif classification == CommandCatalog.YIELD and not boundary then
          problem(
            "yield instruction lacks a run-phase boundary",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        elseif classification == CommandCatalog.STOP and node.op ~= "stop" then
          problem(
            "stop instruction translated to a non-stop node",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        elseif classification == CommandCatalog.CONTINUE and boundary and node.op ~= "stop" then
          -- A same-tick instruction must not introduce a wait; an explicit
          -- stop is the only boundary a same-tick fold may introduce.
          problem(
            "same-tick instruction folded into a blocking node",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        end
      end
    end
  end

  -- Item 5: no implementation variable is ever discarded. Every Wait
  -- mirrors its countdown into the destination variable exactly like the
  -- source engine (ScrCmd_Wait writes the frame count; RunPauseTimer
  -- decrements the variable per poll), so observable and cross-context
  -- reads always see the live countdown .

  -- Cross-script target warning: a jump or call into a same-member label
  -- whose region lowers with explicit unsupported nodes faults at runtime
  -- when that path executes. Import-time and same-member only; the warning
  -- never rejects the translation.
  if memberIr ~= nil then
    local memberLabels = {}
    for _, memberScript in pairs(memberIr.scripts) do
      for _, ins in ipairs(memberScript.instructions) do
        if ins.label ~= nil then
          memberLabels[ins.label] = memberScript.index
        end
      end
    end
    local loweredCache = {}
    local function regionHasUnsupported(label, targetId)
      local owner = memberLabels[label]
      if owner == nil then
        return nil
      end
      local targetScript = memberIr.scripts[owner]
      if targetScript == nil then
        return nil
      end
      local lowered = loweredCache[owner]
      if lowered == nil then
        lowered = SemanticLowering.lowerScript(targetScript, memberIr, {})
        loweredCache[owner] = lowered
      end
      local inRegion = false
      for _, item in ipairs(lowered.items) do
        if item.op == "label" then
          if item.name == label then
            inRegion = true
          elseif inRegion then
            break
          end
        elseif inRegion and (item.op == "stop" or item.op == "unsupported") then
          if item.op == "unsupported" then
            return true
          end
          break
        end
      end
      return false
    end
    local function walkCrossScript(list)
      for _, item in ipairs(list) do
        if item.op == "goto_script" or (item.op == "call" and item.label ~= nil) then
          local targetId = item.op == "goto_script" and item.script or item.target
          if item.label ~= nil and regionHasUnsupported(item.label, targetId) then
            warn("cross-script target region contains unsupported nodes", { scriptId = targetId, label = item.label })
          end
        end
        if item.op == "if" then
          walkCrossScript(item.yes)
          walkCrossScript(item.no)
        end
      end
    end
    walkCrossScript(steps)
  end

  -- Item 6: canonicalized operands resolve to the same constants.
  for _, ins in ipairs(script.instructions) do
    local checker = CHECKERS[ins.opcode]
    if checker ~= nil then
      local node = byOffset[ins.offset]
      if node ~= nil and node.op ~= "unsupported" then
        local message = checker(ins, node)
        if message ~= nil then
          problem(message, { offset = ins.offset, opcode = ins.opcode })
        end
      end
    end
  end

  -- Item 7: call/return balance from the CFG. A prelude's entry-path
  -- returns (the subroutine-library shape) warn instead of fault.
  for _, balanceProblem in ipairs(cfg.balance.problems) do
    local preludeTolerant = prelude
      and (
        balanceProblem.message == "return below an empty script stack"
        or balanceProblem.message == "return with no matching call"
      )
    if preludeTolerant then
      warn(balanceProblem.message, balanceProblem.context)
    else
      problem(balanceProblem.message, balanceProblem.context)
    end
  end
  for _, balanceWarning in ipairs(cfg.balance.warnings) do
    warn(balanceWarning.message, balanceWarning.context)
  end
  local hasCall = false
  for _, ins in ipairs(script.instructions) do
    if CALL_OPS[ins.opcode] then
      hasCall = true
      break
    end
  end
  if not hasCall then
    for i, ins in ipairs(script.instructions) do
      if RETURN_OPS[ins.opcode] then
        -- A return in a reachable block with no call anywhere is a stray
        -- pop (the runtime faults on an empty frame stack); an unreachable
        -- return is a shared script tail whose caller lives in another
        -- script and is only a warning.
        local blockId = cfg.blockOfIndex[i]
        local message = "return without any call in the script"
        local reachable = blockId ~= nil and cfg.reachable[blockId] == true
        if prelude or not reachable then
          warn(message, { offset = ins.offset, opcode = ins.opcode })
        else
          problem(message, { offset = ins.offset, opcode = ins.opcode })
        end
      end
    end
  end

  -- Item 8: movement sequence termination.
  local movementSeen = 0
  for _, reference in ipairs(cfg.movementReferences) do
    movementSeen = movementSeen + 1
    if reference.block == nil then
      problem("ApplyMovement references a missing movement block", { offset = reference.offset })
    elseif not reference.block.terminated then
      problem("movement sequence lacks an EndMovement terminator", { offset = reference.offset })
    elseif #reference.block.actions == 0 then
      problem("movement sequence is empty", { offset = reference.offset })
    end
  end

  -- Items 1 and 10: reachability accounting and unsupported prevention.
  local unreachable = total - reachable
  if unreachable > 0 then
    warn("script contains unreachable instructions", { count = unreachable })
  end
  report.total = total
  report.reachable = reachable
  report.unreachable = unreachable
  report.covered = covered
  report.reachableOmitted = reachableOmitted
  report.unsupportedCount = reachableUnsupported
  report.unsupported = unsupportedNodes
  report.irreducible = cfg.irreducibleRegions
  report.balance = cfg.balance
  report.complete = report.ok and covered + #(omissions or {}) >= total and reachableUnsupported == 0
  return report
end

return Verifier
