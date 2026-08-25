-- Script control-flow graph : builds basic blocks, edges,
-- reachability, irreducible regions, and call/return balance from the Raw IR
-- instruction list. Branch and call targets resolve either through the
-- symbolic labels of the decomp assembly or the relative word offsets of the
-- binary member. The graph is what the verifier uses to prove translation
-- accounting : every reachable instruction, every control
-- edge, and every call/return site. Pure domain module: no love dependency.

local Cfg = {}

-- Instruction opcodes with structural meaning.
local OP_GOTO = 22
local OP_OBJECT_GOTO = 23
local OP_BG_GOTO = 24
local OP_DIRECTION_GOTO = 25
local OP_CALL = 26
local OP_RETURN = 27
local OP_GOTO_IF = 28
local OP_CALL_IF = 29
local OP_END = 2

-- Resolve a branch/call operand to an absolute target offset. Decomp
-- operands are label symbols; binary operands are relative word offsets
-- from the end of the instruction (ScriptReadWord semantics).
---@param ins table
---@param operandIndex integer
---@param labels table<string, integer>
---@return integer|nil offset
local function resolveTarget(ins, operandIndex, labels)
  local operand = ins.operands[operandIndex]
  if operand == nil then
    return nil
  end
  local raw = operand.raw
  if type(raw) == "string" then
    return labels[raw]
  end
  if type(raw) ~= "number" then
    return nil
  end
  return ins.offset + ins.size + raw
end

-- The successors of one instruction: `{ kind, targetOffset? }` pairs.
---@param ins table
---@param labels table<string, integer>
---@return table[] successors
local function successorsOf(ins, labels)
  local opcode = ins.opcode
  if opcode == OP_GOTO then
    return { { kind = "branch", targetOffset = resolveTarget(ins, 1, labels) } }
  elseif opcode == OP_OBJECT_GOTO or opcode == OP_BG_GOTO or opcode == OP_DIRECTION_GOTO or opcode == OP_GOTO_IF then
    return {
      { kind = "fallthrough" },
      { kind = "branch", targetOffset = resolveTarget(ins, 2, labels) },
    }
  elseif opcode == OP_CALL then
    return {
      { kind = "call", targetOffset = resolveTarget(ins, 1, labels) },
      { kind = "fallthrough" },
    }
  elseif opcode == OP_CALL_IF then
    return {
      { kind = "fallthrough" },
      { kind = "call", targetOffset = resolveTarget(ins, 2, labels) },
    }
  elseif opcode == OP_RETURN then
    return { { kind = "return" } }
  elseif opcode == OP_END then
    return { { kind = "stop" } }
  end
  return { { kind = "fallthrough" } }
end

-- Build the CFG for one script. `memberIr` is optional and supplies the
-- movement blocks that ApplyMovement references (movement-sequence roots).
---@param script table
---@param memberIr table|nil
---@return table cfg
function Cfg.build(script, memberIr)
  local instructions = script.instructions
  local empty = {
    instructions = instructions,
    blocks = {},
    blockOfIndex = {},
    entryId = nil,
    reachable = {},
    irreducible = {},
    irreducibleRegions = {},
    balance = { ok = true, problems = {}, warnings = {} },
    labels = {},
    movementReferences = {},
  }
  if #instructions == 0 then
    return empty
  end
  local labels = {}
  for _, ins in ipairs(instructions) do
    if ins.label ~= nil then
      labels[ins.label] = ins.offset
    end
  end
  local offsetToIndex = {}
  for i, ins in ipairs(instructions) do
    offsetToIndex[ins.offset] = i
  end

  local successors = {}
  for i, ins in ipairs(instructions) do
    successors[i] = successorsOf(ins, labels)
  end

  -- Leaders: script entry, branch/call targets, and the instruction after a
  -- terminator (no fallthrough successor).
  local leaders = {}
  leaders[1] = true
  for i, succs in ipairs(successors) do
    for _, succ in ipairs(succs) do
      if succ.targetOffset ~= nil then
        local target = offsetToIndex[succ.targetOffset]
        if target ~= nil then
          leaders[target] = true
        end
      end
    end
    -- Any instruction that does not simply fall through ends its block, so
    -- the next instruction starts a new block (a join point for branches
    -- and calls, or unreachable tail code after a goto/return/end).
    local straight = #succs == 1 and succs[1].kind == "fallthrough"
    if not straight and i < #instructions then
      leaders[i + 1] = true
    end
  end

  -- Split into blocks.
  local blocks = {}
  local blockOfIndex = {}
  local current = nil
  local function closeBlock(blockId)
    if current ~= nil then
      local lastIndex = current.indices[#current.indices]
      current.terminator = successors[lastIndex][1].kind
      current.successors = {}
      for _, succ in ipairs(successors[lastIndex]) do
        if succ.kind == "stop" or succ.kind == "return" then
          current.successors[#current.successors + 1] = { kind = succ.kind }
        elseif succ.kind == "branch" or succ.kind == "call" then
          local targetIndex = succ.targetOffset ~= nil and offsetToIndex[succ.targetOffset] or nil
          current.successors[#current.successors + 1] = {
            kind = succ.kind,
            targetIndex = targetIndex,
            targetOffset = succ.targetOffset,
          }
          if targetIndex ~= nil then
            leaders[targetIndex] = true
          end
        else
          current.successors[#current.successors + 1] = { kind = "fallthrough" }
        end
      end
      blocks[blockId] = current
      current = nil
    end
  end
  local blockCounter = 0
  for i, _ in ipairs(instructions) do
    if leaders[i] then
      closeBlock(blockCounter)
      blockCounter = blockCounter + 1
      current = { id = blockCounter, entryIndex = i, indices = {} }
    end
    local block = current --[[@as { id: integer, entryIndex: integer, indices: integer[], terminator: string|nil, successors: table[] }]]
    block.indices[#block.indices + 1] = i
    blockOfIndex[i] = block.id
  end
  closeBlock(blockCounter)

  -- Resolve fallthrough successors to block ids.
  for _, block in pairs(blocks) do
    local lastIndex = block.indices[#block.indices]
    for _, succ in ipairs(block.successors) do
      if succ.kind == "fallthrough" then
        local nextBlock = blockOfIndex[lastIndex + 1]
        succ.targetIndex = nextBlock
      elseif succ.targetIndex ~= nil then
        succ.targetIndex = blockOfIndex[succ.targetIndex]
      end
    end
    block.entryOffset = instructions[block.indices[1]].offset
  end

  -- Reachability from the entry block.
  local entryId = blockOfIndex[1]
  local reachable = {}
  local function markReachable(start)
    local queue = { start }
    while #queue > 0 do
      local blockId = table.remove(queue, 1)
      if not reachable[blockId] then
        reachable[blockId] = true
        for _, succ in ipairs(blocks[blockId].successors) do
          if succ.targetIndex ~= nil and not reachable[succ.targetIndex] then
            queue[#queue + 1] = succ.targetIndex
          end
        end
      end
    end
  end
  markReachable(entryId)

  -- Irreducible regions: a strongly connected component with more than one
  -- entry edge from outside the component (the classic characterization:
  -- a reducible flow graph has a unique entry per SCC).
  local irreducible = {}
  local region = {}
  local function stronglyConnected()
    local index = 0
    local stack = {}
    local onStack = {}
    local indices = {}
    local lowlink = {}
    local function visit(blockId)
      index = index + 1
      indices[blockId] = index
      lowlink[blockId] = index
      stack[#stack + 1] = blockId
      onStack[blockId] = true
      for _, succ in ipairs(blocks[blockId].successors) do
        local target = succ.targetIndex
        if target ~= nil and reachable[target] then
          if indices[target] == nil then
            visit(target)
            lowlink[blockId] = math.min(lowlink[blockId], lowlink[target])
          elseif onStack[target] then
            lowlink[blockId] = math.min(lowlink[blockId], indices[target])
          end
        end
      end
      if lowlink[blockId] == indices[blockId] then
        local component = {}
        local inside = {}
        while #stack > 0 do
          local member = table.remove(stack)
          onStack[member] = nil
          component[#component + 1] = member
          inside[member] = true
          if member == blockId then
            break
          end
        end
        if
          #component > 1
          or (blocks[blockId].successors[1].kind == "branch" and blocks[blockId].successors[1].targetIndex == blockId)
        then
          -- Count the entry edges from outside the component.
          local entries = 0
          local seen = {}
          for _, member in ipairs(component) do
            for predId, pred in pairs(blocks) do
              if reachable[predId] and not inside[predId] then
                for _, succ in ipairs(pred.successors) do
                  if succ.targetIndex == member and not seen[succ] then
                    seen[succ] = true
                    entries = entries + 1
                  end
                end
              end
            end
          end
          if entries > 1 then
            for _, member in ipairs(component) do
              irreducible[member] = true
            end
            region[#region + 1] = { blocks = component, entries = entries }
          end
        end
      end
    end
    visit(entryId)
  end
  stronglyConnected()

  -- Call/return balance: propagate stack heights over (block, height)
  -- states. Falls through and branches keep the height; call edges add one;
  -- returns require a frame and terminate. A stop with open call frames is
  -- a documented source idiom (subroutines that End instead of Return
  -- unwind the whole context), so it is reported as a warning, not a
  -- violation.
  local balance = { ok = true, problems = {}, warnings = {} }
  local function blockDelta(block)
    -- The cumulative stack delta across the whole block (including its
    -- terminator), the minimum prefix sum, and the delta before the
    -- terminator (a CallIf fallthrough skips the push).
    local delta = 0
    local min = 0
    local cum = 0
    for _, i in ipairs(block.indices) do
      local opcode = instructions[i].opcode
      local step = 0
      if opcode == OP_CALL or opcode == OP_CALL_IF then
        step = 1
      elseif opcode == OP_RETURN then
        step = -1
      end
      cum = cum + step
      min = math.min(min, cum)
      delta = delta + step
    end
    local pre = delta
    if #block.indices > 0 then
      local opcode = instructions[block.indices[#block.indices]].opcode
      local terminatorStep = 0
      if opcode == OP_CALL or opcode == OP_CALL_IF then
        terminatorStep = 1
      elseif opcode == OP_RETURN then
        terminatorStep = -1
      end
      pre = delta - terminatorStep
    end
    return pre, delta, min
  end
  local seen = {}
  local pending = { { id = entryId, height = 0 } }
  local maxCalls = 0
  for _, ins in ipairs(instructions) do
    if ins.opcode == OP_CALL or ins.opcode == OP_CALL_IF then
      maxCalls = maxCalls + 1
    end
  end
  while #pending > 0 do
    local state = table.remove(pending, 1)
    local key = state.id .. ":" .. state.height
    if not seen[key] then
      seen[key] = true
      local block = blocks[state.id]
      local pre, post, min = blockDelta(block)
      local function report(message, context)
        balance.ok = false
        balance.problems[#balance.problems + 1] = { message = message, context = context }
      end
      if state.height + min < 0 then
        report("return below an empty script stack", { block = state.id, entryOffset = block.entryOffset })
      end
      local terminator = block.successors[1]
      if terminator.kind == "return" and state.height + post < 0 then
        report("return with no matching call", { block = state.id, entryOffset = block.entryOffset })
      end
      if terminator.kind == "stop" and state.height + post ~= 0 then
        balance.warnings[#balance.warnings + 1] = {
          message = "script ends with a non-empty call stack",
          context = { block = state.id, entryOffset = block.entryOffset, height = state.height + post },
        }
      end
      for _, succ in ipairs(block.successors) do
        local nextHeight
        if succ.kind == "call" then
          -- The pushed frame is visible on both the called side and (for a
          -- plain Call) the fallthrough side.
          nextHeight = state.height + post
        elseif succ.kind == "fallthrough" or succ.kind == "branch" then
          -- A CallIf fallthrough skips the push; every other terminator
          -- keeps the full post-sum on its outgoing edges.
          if terminator.kind == "call_if" then
            nextHeight = state.height + pre
          else
            nextHeight = state.height + post
          end
        end
        if nextHeight ~= nil and succ.targetIndex ~= nil and nextHeight <= maxCalls then
          pending[#pending + 1] = { id = succ.targetIndex, height = nextHeight }
        end
      end
    end
  end

  -- Movement-sequence roots referenced by ApplyMovement.
  local movementReferences = {}
  if memberIr ~= nil then
    for _, ins in ipairs(instructions) do
      if ins.opcode == 94 then
        local raw = ins.operands[2] and ins.operands[2].raw or nil
        local offset = type(raw) == "string" and tonumber(raw:sub(2), 16) or raw
        movementReferences[#movementReferences + 1] = {
          offset = offset,
          block = memberIr.movements[offset],
        }
      end
    end
  end

  return {
    instructions = instructions,
    blocks = blocks,
    blockOfIndex = blockOfIndex,
    entryId = entryId,
    reachable = reachable,
    irreducible = irreducible,
    irreducibleRegions = region,
    balance = balance,
    labels = labels,
    movementReferences = movementReferences,
  }
end

return Cfg
