-- Analyzes reachable raw SSEQ commands using the ARM7 shared CALL/LOOP
-- continuation stack. This source-format analysis is shared by lowering and
-- corpus inspection; it never produces runtime sequence instructions.

local Errors = require("libs.errors.src.Errors")
local Sseq = require("romdump.src.digest.audio.Sseq")

local SequenceReachability = {}

local function stackKey(stack)
  local parts = {}
  for index, frame in ipairs(stack) do
    parts[index] = frame.kind .. ":" .. frame.returnOffset .. ":" .. (frame.countClass or "")
  end
  return table.concat(parts, ";")
end

local function copyStack(stack)
  local result = {}
  for index, frame in ipairs(stack) do
    result[index] = frame
  end
  return result
end

local function push(stack, frame)
  local result = copyStack(stack)
  result[#result + 1] = frame
  return result
end

local function classifyLoopCount(value)
  if type(value) ~= "number" then
    return "unknown"
  end
  value = value % 256
  if value == 0 then
    return "zero"
  end
  if value == 1 then
    return "one"
  end
  return "many"
end

local function addSuccessor(queue, offset, stack, trackSlot)
  queue[#queue + 1] = { offset = offset, stack = stack, trackSlot = trackSlot }
end

local function visitSuccessors(command, state, dataOffset, queue, branchTargets)
  local opcode = command.opcode
  local stack = state.stack
  local nextOffset = command.next
  local function skipped()
    addSuccessor(queue, nextOffset, stack, state.trackSlot)
  end

  if opcode == 0x93 then
    addSuccessor(queue, nextOffset, stack, state.trackSlot)
    if command.track ~= state.trackSlot then
      branchTargets[command.offset] = true
      addSuccessor(queue, dataOffset + command.target, {}, command.track)
    end
  elseif opcode == 0x94 then
    if command.conditional then
      skipped()
    end
    branchTargets[command.offset] = true
    addSuccessor(queue, dataOffset + command.target, stack, state.trackSlot)
  elseif opcode == 0x95 then
    if command.conditional then
      skipped()
    end
    if #stack < 3 then
      branchTargets[command.offset] = true
      addSuccessor(
        queue,
        dataOffset + command.target,
        push(stack, {
          kind = "call",
          returnOffset = nextOffset,
        }),
        state.trackSlot
      )
    else
      skipped()
    end
  elseif opcode == 0xFD then
    if command.conditional then
      skipped()
    end
    if #stack == 0 then
      addSuccessor(queue, nextOffset, stack, state.trackSlot)
    else
      addSuccessor(queue, stack[#stack].returnOffset, {
        table.unpack(stack, 1, #stack - 1),
      }, state.trackSlot)
    end
  elseif opcode == 0xD4 then
    if command.conditional then
      skipped()
    end
    if #stack < 3 then
      addSuccessor(
        queue,
        nextOffset,
        push(stack, {
          kind = "loop",
          returnOffset = nextOffset,
          countClass = classifyLoopCount(command.value),
        }),
        state.trackSlot
      )
    else
      skipped()
    end
  elseif opcode == 0xFC then
    if command.conditional then
      skipped()
    end
    local frame = stack[#stack]
    if frame == nil then
      addSuccessor(queue, nextOffset, stack, state.trackSlot)
    elseif frame.kind ~= "loop" then
      addSuccessor(queue, nextOffset, stack, state.trackSlot)
      addSuccessor(queue, frame.returnOffset, stack, state.trackSlot)
    elseif frame.countClass == "zero" then
      addSuccessor(queue, frame.returnOffset, stack, state.trackSlot)
    elseif frame.countClass == "one" then
      addSuccessor(queue, nextOffset, {
        table.unpack(stack, 1, #stack - 1),
      }, state.trackSlot)
    else
      addSuccessor(queue, frame.returnOffset, stack, state.trackSlot)
      addSuccessor(queue, nextOffset, {
        table.unpack(stack, 1, #stack - 1),
      }, state.trackSlot)
    end
  elseif opcode == 0xFF then
    if command.conditional then
      skipped()
    end
  else
    addSuccessor(queue, nextOffset, stack, state.trackSlot)
  end
end

local function _analyze(bytes, context)
  local source = context or "SSEQ"
  local seq, err = Sseq.open(bytes, source)
  if seq == nil then
    error(err)
  end
  local endPos = #bytes
  local dataOffset = seq.dataOffset
  local pos = dataOffset
  local trackMask
  if pos < endPos and string.byte(bytes, pos + 1) == 0xFE then
    if pos + 3 > endPos then
      Errors.raise("SSEQ_TRUNCATED", "track mask runs past the end of the sequence", {
        source = source,
        offset = dataOffset,
      })
    end
    trackMask = string.byte(bytes, pos + 2) + string.byte(bytes, pos + 3) * 256
    pos = pos + 3
  end
  local entryOffset = pos
  if entryOffset >= endPos then
    Errors.raise("SSEQ_TRUNCATED", "sequence contains no commands", {
      source = source,
      offset = entryOffset,
    })
  end

  local queue = { { offset = entryOffset, stack = {}, trackSlot = 0 } }
  local seenStates = {}
  local commandsByOffset = {}
  local branchTargets = {}
  while #queue > 0 do
    local state = table.remove(queue)
    if state.offset < endPos then
      local key = state.offset .. "|" .. state.trackSlot .. "|" .. stackKey(state.stack)
      if not seenStates[key] then
        seenStates[key] = true
        local command = commandsByOffset[state.offset]
        if command == nil then
          command, err = Sseq.decodeCommand(bytes, state.offset, endPos, source)
          if command == nil then
            error(err)
          end
          commandsByOffset[state.offset] = command
        end
        visitSuccessors(command, state, dataOffset, queue, branchTargets)
      end
    end
  end

  local offsets = {}
  for offset in pairs(commandsByOffset) do
    offsets[#offsets + 1] = offset
  end
  table.sort(offsets)
  return {
    dataOffset = dataOffset,
    entryOffset = entryOffset,
    trackMask = trackMask,
    commandsByOffset = commandsByOffset,
    branchTargets = branchTargets,
    offsets = offsets,
  }
end

---@param bytes string
---@param context string?
---@return table?|nil
---@return Errors.Error?|nil
function SequenceReachability.analyze(bytes, context)
  local ok, result = pcall(_analyze, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return SequenceReachability
