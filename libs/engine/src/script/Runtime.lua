-- Internal graph node execution: the runtime executes compiled graphs, never
-- authoring tables. Every node handler returns exactly one outcome:
-- `continue`, `yield_tick`, `block`, or `stop`. Attributed faults (missing
-- actors, background-forbidden operations, lock violations, task failures)
-- raise Errors objects that the scheduler's run loop converts into faulted
-- instances. Value and condition evaluation also live here because task
-- implementations share them. Pure domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local ScriptEnvironment = require("libs.engine.src.script.ScriptEnvironment")

local Runtime = {}

Runtime.OUTCOME_CONTINUE = "continue"
Runtime.OUTCOME_YIELD_TICK = "yield_tick"
Runtime.OUTCOME_BLOCK = "block"
Runtime.OUTCOME_STOP = "stop"

-- The opposite facing, for `facePlayer` (the actor turns toward the player).
local OPPOSITE_FACING = { north = "south", south = "north", west = "east", east = "west" }

-- --- Reference evaluation -----------------------------------------------------

-- Write a value reference: locals and vars are writable; args are read-only
-- call data (writing one is an invalid reference). Shared by node handlers
-- and the scheduler's task-result write.
---@param ref any
---@param value any
---@param run table
function Runtime.writeRef(ref, value, run)
  if type(ref) ~= "table" or ref.value == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "result reference is not a value",
      { scriptId = run.instance.scriptId, nodeId = run.node.nodeId }
    )
  end
  if ref.value == "local" then
    run.instance.locals[ref.name] = value
    return
  end
  if ref.value == "var" then
    run.services.world:setVar(ref.id, value)
    return
  end
  Errors.raise(
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "cannot write to a " .. ref.value .. " reference",
    { scriptId = run.instance.scriptId, nodeId = run.node.nodeId }
  )
end

-- Evaluate a value reference to a runtime scalar.
---@param v any
---@param run table
---@return any
function Runtime.evaluateValue(v, run)
  if type(v) ~= "table" or v.value == nil then
    return v
  end
  local kind = v.value
  if kind == "var" then
    return run.services.world:getVar(v.id)
  elseif kind == "local" then
    local value = run.instance.locals[v.name]
    if value == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "unset local " .. v.name,
        { scriptId = run.instance.scriptId, localName = v.name }
      )
    end
    return value
  elseif kind == "arg" then
    local frame = run.instance:topFrame()
    local value = frame and frame.args and frame.args[v.name]
    if value == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "unset argument " .. v.name,
        { scriptId = run.instance.scriptId, argName = v.name }
      )
    end
    return value
  elseif kind == "flag_value" then
    local flagId = Runtime.evaluateValue(v.flag, run)
    return run.services.world:isFlagSet(flagId) and 1 or 0
  elseif kind == "player_gender_value" then
    return run.services.player:gender()
  elseif kind == "object_id" then
    local actorId = Runtime.resolveActor(v.ref, run)
    local id = run.services.actors:id(actorId)
    if id == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
        "actor has no numeric id",
        { scriptId = run.instance.scriptId, actor = tostring(actorId) }
      )
    end
    return id
  elseif kind == "trigger_background_id" then
    local backgroundId = run.instance.trigger and run.instance.trigger.backgroundId
    if backgroundId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "no background trigger context",
        { scriptId = run.instance.scriptId }
      )
    end
    return backgroundId
  elseif kind == "trigger_direction" then
    local playerFacing = run.instance.trigger and run.instance.trigger.playerFacing
    if playerFacing == nil then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "no trigger context", { scriptId = run.instance.scriptId })
    end
    return playerFacing
  end
  Errors.raise(
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "unknown value kind " .. tostring(kind),
    { scriptId = run.instance.scriptId }
  )
end

-- Evaluate a condition to a boolean.
---@param condition any
---@param run table
---@return boolean
function Runtime.evaluateCondition(condition, run)
  if type(condition) ~= "table" or condition.condition == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "expected a condition descriptor",
      { scriptId = run.instance.scriptId }
    )
  end
  local kind = condition.condition
  if kind == "compare" then
    local left = Runtime.evaluateValue(condition.left, run)
    local right = Runtime.evaluateValue(condition.right, run)
    local op = condition.operator
    if op == "eq" then
      return left == right
    end
    if op == "ne" then
      return left ~= right
    end
    if type(left) ~= type(right) then
      return false
    end
    if op == "lt" then
      return left < right
    end
    if op == "le" then
      return left <= right
    end
    if op == "gt" then
      return left > right
    end
    if op == "ge" then
      return left >= right
    end
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "unknown compare operator " .. tostring(op),
      { scriptId = run.instance.scriptId }
    )
  elseif kind == "flag" then
    local flagId = Runtime.evaluateValue(condition.id, run)
    return run.services.world:isFlagSet(flagId) == condition.expected
  elseif kind == "not" then
    return not Runtime.evaluateCondition(condition.operand, run)
  elseif kind == "all" then
    for _, sub in ipairs(condition.conditions) do
      if not Runtime.evaluateCondition(sub, run) then
        return false
      end
    end
    return true
  elseif kind == "any" then
    for _, sub in ipairs(condition.conditions) do
      if Runtime.evaluateCondition(sub, run) then
        return true
      end
    end
    return false
  elseif kind == "actor_exists" then
    return Runtime.actorExists(condition.ref, run)
  elseif kind == "truthy" then
    local value = Runtime.evaluateValue(condition.value, run)
    return value ~= false and value ~= nil
  end
  Errors.raise(
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "unknown condition kind " .. tostring(kind),
    { scriptId = run.instance.scriptId }
  )
  return false
end

-- Resolve an actor reference to a concrete actor id. Special references
-- resolve through the trigger context and the actor world adapter.
---@param ref any
---@param run table
---@return string
function Runtime.resolveActor(ref, run)
  if type(ref) == "string" then
    return ref
  end
  if ref.ref ~= "actor" then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "expected an actor reference",
      { scriptId = run.instance.scriptId }
    )
  end
  if ref.mapIndex ~= nil then
    -- A numeric local map-object index: resolve against the current map
    -- through the actor adapter (the pinned
    -- MapObjectManager_GetFirstActiveObjectByID path).
    local actorId
    if run.services.actors.actorIdForMapIndex ~= nil then
      actorId = run.services.actors:actorIdForMapIndex(ref.mapIndex)
    end
    if actorId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
        "map object index " .. tostring(ref.mapIndex) .. " does not resolve in the current map",
        { scriptId = run.instance.scriptId, mapIndex = ref.mapIndex }
      )
    end
    return actorId
  end
  if ref.special ~= nil then
    local trigger = run.instance.trigger
    local actorId
    if ref.special == "player" then
      actorId = "player"
    elseif ref.special == "self" then
      actorId = trigger and trigger.selfActor or nil
    elseif ref.special == "last_talked" then
      actorId = trigger and trigger.selfActor or nil
    elseif ref.special == "partner" then
      actorId = run.services.actors:partnerId()
    elseif ref.special == "camera_target" then
      if run.services.actors.cameraTargetId ~= nil then
        actorId = run.services.actors:cameraTargetId()
      end
    end
    if actorId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
        "actor special " .. ref.special .. " has no target in the trigger context",
        { scriptId = run.instance.scriptId, special = ref.special }
      )
    end
    return actorId
  end
  return ref.id
end

-- Resolve and require a live actor; missing actors are attributed errors.
---@param ref any
---@param run table
---@return string actorId
function Runtime.requireActor(ref, run)
  local actorId = Runtime.resolveActor(ref, run)
  if not run.services.actors:exists(actorId) then
    Errors.raise(
      ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
      "no live actor " .. tostring(actorId),
      { scriptId = run.instance.scriptId, actor = tostring(actorId) }
    )
  end
  return actorId
end

---@param ref any
---@param run table
---@return boolean
function Runtime.actorExists(ref, run)
  local actorId = Runtime.resolveActor(ref, run)
  return run.services.actors:exists(actorId)
end

-- Background-mode restriction: background scripts may never lock player
-- input, open foreground dialogue, warp, or move the player.
---@param run table
local function requireForeground(run, op)
  if run.instance.mode == "background" then
    Errors.raise(
      ScriptErrors.SCRIPT_BACKGROUND_FORBIDDEN,
      op .. " is not allowed in a background script",
      { scriptId = run.instance.scriptId, op = op, instanceId = run.instance.instanceId }
    )
  end
end

-- The player is never a script-controlled actor in a background script.
---@param run table
---@param actorId string
local function requireForegroundPlayer(run, actorId)
  if actorId == "player" and run.instance.mode == "background" then
    Errors.raise(
      ScriptErrors.SCRIPT_BACKGROUND_FORBIDDEN,
      "background scripts may not move the player",
      { scriptId = run.instance.scriptId, instanceId = run.instance.instanceId }
    )
  end
end

-- Create a blocking task through the scheduler and return the block outcome.
-- The blocking node's `result` ref (ask_yes_no, lua) rides along so the
-- scheduler can write the completed task result on continuation.
---@param run table
---@param taskType string
---@param spec table
local function blockOnTask(run, taskType, spec)
  local taskId = run.scheduler:createTask(taskType, spec, run.instance, run.tick, run.input)
  run.blockTaskId = taskId
  run.blockResultRef = run.node and run.node.result or nil
  return Runtime.OUTCOME_BLOCK
end

-- Advance the composition chain: pop the current chain frame and push the
-- next entry's frame. With no next entry, return to the caller or complete.
-- Used by the `next` node and by falling off a linear tail.
---@param run table
---@param frame table
---@return string outcome
local function advanceChain(run, frame)
  local entries = frame.chain
  -- entryIndex is zero-based; the chain is a 1-based Lua array.
  local nextIndex = frame.composition.entryIndex + 1
  if nextIndex < #entries then
    local popped = run.instance:popFrame()
    local entry = entries[nextIndex + 1]
    run.instance:pushFrame(run.instance:makeFrame(entry.graph, entry.graph.entry, {
      returnNodeId = popped.returnNodeId,
      resultRef = popped.resultRef,
      args = frame.args,
      chain = entries,
      chainScriptId = frame.chainScriptId,
      chainRevision = frame.chainRevision,
      composition = {
        entryIndex = nextIndex,
        operation = entry.operation,
        owner = entry.owner,
      },
    }))
    return Runtime.OUTCOME_CONTINUE
  end
  local popped = run.instance:popFrame()
  if run.instance:topFrame() ~= nil then
    run.instance:resumeCaller(popped)
    return Runtime.OUTCOME_CONTINUE
  end
  return Runtime.OUTCOME_STOP
end

-- Evaluate a call's args against the current frame and store them on a fresh
-- frame (values are evaluated at call time).
---@param node table
---@param run table
---@return table
local function evaluatedArgs(node, run)
  local args = {}
  for name, ref in pairs(node.args or {}) do
    args[name] = Runtime.evaluateValue(ref, run)
  end
  return args
end

-- Push the entry frame of a composed script (the first chain entry),
-- entering at `nodeId` when given (a label inside the entry graph) or at
-- the composed entry otherwise.
---@param run table
---@param composed table
---@param args table
---@param returnNodeId string|nil
local function pushComposedFrame(run, composed, args, returnNodeId, nodeId)
  local entries = composed.entries
  assert(#entries > 0, "composed script has no entries")
  local entry = entries[1]
  run.instance:pushFrame(run.instance:makeFrame(entry.graph, nodeId or entry.graph.entry, {
    returnNodeId = returnNodeId,
    resultRef = returnNodeId ~= nil and run.node.result or nil,
    args = args,
    chain = entries,
    chainScriptId = composed.scriptId,
    chainRevision = composed.revision,
    composition = {
      entryIndex = 0,
      operation = entry.operation,
      owner = entry.owner,
    },
  }))
end

-- The graph and entry node id of a composed script, entering at `label`
-- when given (a label inside the composed entry graph) or at the entry
-- otherwise. A missing label is an attributed label error.
---@param run table
---@param composed table
---@param label string|nil
---@return table graph, string nodeId
local function composedEntryAt(run, composed, label)
  local entries = composed.entries
  assert(#entries > 0, "composed script has no entries")
  local entry = entries[1]
  if label == nil then
    return entry.graph, entry.graph.entry
  end
  local nodeId = entry.graph.labels[label]
  if nodeId == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_LABEL_MISSING,
      "composed script has no label " .. label,
      { scriptId = composed.scriptId, label = label }
    )
  end
  return entry.graph, nodeId
end

-- Resolve a call target through the scheduler's composition resolver; a
-- missing target is an attributed call error.
---@param run table
---@param target string
local function resolveCallTarget(run, target)
  local composed = run.scheduler:resolveComposition(target)
  if composed == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_CALL_TARGET_MISSING,
      "no composed script for call target " .. target,
      { scriptId = run.instance.scriptId, target = target }
    )
  end
  return composed
end

-- --- Node handlers ------------------------------------------------------------

local HANDLERS = {}

-- The step budget consumes one unit per continue outcome; handlers below that
-- continue set the frame's pc or push frames themselves.

HANDLERS.noop = function(node, run)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.label = function(node, run)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.stop = function(node, run)
  return Runtime.OUTCOME_STOP
end

HANDLERS.yield_tick = function(node, run)
  return Runtime.OUTCOME_YIELD_TICK
end

HANDLERS["if"] = function(node, run)
  local frame = run.instance:topFrame()
  if Runtime.evaluateCondition(node.condition, run) then
    frame.nodeId = node.yes
  else
    frame.nodeId = node.no
  end
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.switch = function(node, run)
  local frame = run.instance:topFrame()
  local value = Runtime.evaluateValue(node.value, run)
  frame.nodeId = node.cases[value] or node.default
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS["goto"] = function(node, run)
  run.instance:topFrame().nodeId = node.targetNode
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.goto_if = function(node, run)
  local frame = run.instance:topFrame()
  if Runtime.evaluateCondition(node.condition, run) then
    frame.nodeId = node.targetNode
  else
    frame.nodeId = node.next
  end
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.compare = function(node, run)
  run.instance.compare = {
    left = Runtime.evaluateValue(node.left, run),
    right = Runtime.evaluateValue(node.right, run),
  }
  return Runtime.OUTCOME_CONTINUE
end

local COMPARE_OPS = {
  lt = function(l, r)
    return l < r
  end,
  eq = function(l, r)
    return l == r
  end,
  gt = function(l, r)
    return l > r
  end,
  le = function(l, r)
    return l <= r
  end,
  ge = function(l, r)
    return l >= r
  end,
  ne = function(l, r)
    return l ~= r
  end,
}

-- Evaluate the low-level compare state against an operator.
---@param operator string
---@param run table
---@return boolean
local function compared(operator, run)
  local compare = run.instance.compare
  if compare == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "compare state is unset", { scriptId = run.instance.scriptId })
  end
  local fn = assert(COMPARE_OPS[operator], "unknown compare operator " .. tostring(operator))
  local cmp = compare --[[@as { left: any, right: any }]]
  return fn(cmp.left, cmp.right)
end

-- Switch the top frame onto a composed target at its entry (or a label
-- inside it), replacing the frame's graph identity and chain attribution so
-- save pinning and ownership follow the target. Shared by the cross-script
-- compare-state jump and `goto_script`; the jump continues in the same tick,
-- matching the source `ScriptJump` semantics.
---@param run table
---@param frame table
---@param composed table
---@param nodeId string
local function switchFrameToComposed(run, frame, composed, nodeId)
  local entries = composed.entries
  local entry = entries[1]
  frame.graph = entry.graph
  frame.graphRevision = entry.graph.revision
  frame.nodeId = nodeId
  frame.chain = entries
  frame.chainScriptId = composed.scriptId
  frame.chainRevision = composed.revision
  frame.composition = {
    entryIndex = 0,
    operation = entry.operation,
    owner = entry.owner,
  }
end

HANDLERS.goto_compared = function(node, run)
  local frame = run.instance:topFrame()
  if compared(node.operator, run) then
    if node.script ~= nil then
      -- Cross-script compare-state jump (shared script tails): resolve the
      -- composed target and switch the frame, consuming the compare state
      -- exactly as the source engine does.
      local composed = resolveCallTarget(run, node.script)
      local _, nodeId = composedEntryAt(run, composed, node.label)
      switchFrameToComposed(run, frame, composed, nodeId)
    else
      frame.nodeId = node.targetNode
    end
  else
    frame.nodeId = node.next
  end
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.call_compared = function(node, run)
  if compared(node.operator, run) then
    return HANDLERS.call(node, run)
  end
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.call = function(node, run)
  local frame = run.instance:topFrame()
  local args = evaluatedArgs(node, run)
  local returnNodeId = node.returnNode
  if node.targetNode ~= nil then
    run.instance:pushFrame(run.instance:makeFrame(frame.graph, node.targetNode, {
      returnNodeId = returnNodeId,
      resultRef = node.result,
      args = args,
      chain = frame.chain,
      chainScriptId = frame.chainScriptId,
      chainRevision = frame.chainRevision,
      composition = frame.composition,
    }))
    return Runtime.OUTCOME_CONTINUE
  end
  local composed = resolveCallTarget(run, node.target or node.script)
  local graph, nodeId = composedEntryAt(run, composed, node.label)
  pushComposedFrame(run, composed, args, returnNodeId, nodeId)
  return Runtime.OUTCOME_CONTINUE
end

-- A cross-script same-context jump (shared script tails): switches the top
-- frame to the composed target at its label (or its entry) and continues in
-- the same tick, matching the source `ScriptJump` semantics.
HANDLERS.goto_script = function(node, run)
  local composed = resolveCallTarget(run, node.script)
  local _, nodeId = composedEntryAt(run, composed, node.label)
  switchFrameToComposed(run, run.instance:topFrame(), composed, nodeId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS["return"] = function(node, run)
  local frame = run.instance:popFrame()
  assert(frame ~= nil, "return with an empty frame stack")
  if node.value ~= nil then
    local value = Runtime.evaluateValue(node.value, run)
    if frame.resultRef ~= nil then
      Runtime.writeRef(frame.resultRef, value, run)
    end
  end
  if run.instance:topFrame() ~= nil then
    run.instance:resumeCaller(frame)
    return Runtime.OUTCOME_CONTINUE
  end
  return Runtime.OUTCOME_STOP
end

HANDLERS.next = function(node, run)
  local frame = run.instance:topFrame()
  if frame.chain == nil or frame.composition == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_WRAPPER_INVALID,
      "next outside a wrapper composition",
      { scriptId = run.instance.scriptId }
    )
  end
  return advanceChain(run, frame)
end

HANDLERS.signal_caller = function(node, run)
  local slot = run.instance.contextSlot
  if slot <= 0 then
    Errors.raise(
      ScriptErrors.SCRIPT_CALLER_SIGNAL_INVALID,
      "signal_caller is only valid inside a common-script child context",
      { scriptId = run.instance.scriptId, contextSlot = slot }
    )
  end
  run.environment:setCallerSignal(slot - 1, false)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.call_common = function(node, run)
  local composed = resolveCallTarget(run, node.target)
  local args = evaluatedArgs(node, run)
  local child, slot, parentSlot = run.scheduler:createCommonChild(composed, args, run)
  local taskId = run.scheduler:createTask("child_script", {
    childInstanceId = child.instanceId,
    childSlot = slot,
    parentSlot = parentSlot,
  }, run.instance, run.tick, run.input)
  run.blockTaskId = taskId
  return Runtime.OUTCOME_BLOCK
end

HANDLERS.set_flag = function(node, run)
  local flagId = Runtime.evaluateValue(node.flag, run)
  run.services.world:setFlag(flagId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.clear_flag = function(node, run)
  local flagId = Runtime.evaluateValue(node.flag, run)
  run.services.world:clearFlag(flagId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.set_var = function(node, run)
  local variableId = Runtime.evaluateValue(node.variable, run)
  local value = Runtime.evaluateValue(node.value, run)
  run.services.world:setVar(variableId, value)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.copy_var = function(node, run)
  local destination = Runtime.evaluateValue(node.destination, run)
  local source = Runtime.evaluateValue(node.source, run)
  run.services.world:setVar(destination, run.services.world:getVar(source))
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.add_var = function(node, run)
  local variableId = Runtime.evaluateValue(node.variable, run)
  local amount = Runtime.evaluateValue(node.amount, run)
  run.services.world:addVar(variableId, amount)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.sub_var = function(node, run)
  local variableId = Runtime.evaluateValue(node.variable, run)
  local amount = Runtime.evaluateValue(node.amount, run)
  run.services.world:subVar(variableId, amount)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.set_local = function(node, run)
  run.instance.locals[node.name] = node.value
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.copy_local = function(node, run)
  run.instance.locals[node.destination] = run.instance.locals[node.source]
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.add_local = function(node, run)
  run.instance.locals[node.name] = (run.instance.locals[node.name] or 0) + node.amount
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.sub_local = function(node, run)
  run.instance.locals[node.name] = (run.instance.locals[node.name] or 0) - node.amount
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.buffer_text = function(node, run)
  run.instance.textArgs[node.slot] = node.value
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.lock_player = function(node, run)
  requireForeground(run, "lock_player")
  run.environment:acquireLock(ScriptEnvironment.LOCK_PLAYER, nil, run.instance.instanceId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.release_player = function(node, run)
  run.environment:releaseLock(ScriptEnvironment.LOCK_PLAYER, nil, run.instance.instanceId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.lock_all = function(node, run)
  requireForeground(run, "lock_all")
  run.environment:acquireLock(ScriptEnvironment.LOCK_PLAYER, nil, run.instance.instanceId)
  run.environment:acquireLock(ScriptEnvironment.LOCK_AUTONOMOUS, nil, run.instance.instanceId)
  if run.environment:hasOutstandingMovement() then
    return blockOnTask(run, "movement_pause", {})
  end
  return Runtime.OUTCOME_YIELD_TICK
end

HANDLERS.release_all = function(node, run)
  run.environment:releaseLock(ScriptEnvironment.LOCK_PLAYER, nil, run.instance.instanceId)
  run.environment:releaseLock(ScriptEnvironment.LOCK_AUTONOMOUS, nil, run.instance.instanceId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.lock_actor = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  run.environment:acquireLock(ScriptEnvironment.LOCK_ACTOR_PREFIX .. actorId, actorId, run.instance.instanceId)
  if node.waitUntilPausable and run.services.actors:isBusy(actorId) then
    return blockOnTask(run, "actor_pause", { actor = actorId })
  end
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.release_actor = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  run.environment:releaseLock(ScriptEnvironment.LOCK_ACTOR_PREFIX .. actorId, actorId, run.instance.instanceId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.face_player = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  local facing = run.services.player:facing()
  run.services.actors:setFacing(actorId, OPPOSITE_FACING[facing])
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.face = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  run.services.actors:setFacing(actorId, node.direction)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.show_object = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  run.services.actors:show(actorId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.hide_object = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  run.services.actors:hide(actorId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.set_object_position = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  run.services.actors:setPosition(actorId, {
    fieldX = node.fieldX,
    fieldZ = node.fieldZ,
    worldY = node.worldY,
  })
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.set_object_facing = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  run.services.actors:setFacing(actorId, node.direction)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.set_object_movement_type = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  run.services.actors:setMovementType(actorId, node.movementType)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.get_player_coords = function(node, run)
  local position = run.services.player:position()
  Runtime.writeRef(node.x, position.fieldX, run)
  Runtime.writeRef(node.z, position.fieldZ, run)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.get_object_coords = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  local position = run.services.actors:getPosition(actorId)
  Runtime.writeRef(node.x, position.fieldX, run)
  Runtime.writeRef(node.z, position.fieldZ, run)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.get_player_facing = function(node, run)
  Runtime.writeRef(node.result, run.services.player:facing(), run)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.random = function(node, run)
  local roll = run.services.world.rng:nextInt(node.maxExclusive)
  Runtime.writeRef(node.result, roll, run)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.apply_movement = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  requireForegroundPlayer(run, actorId)
  local existing = run.scheduler:activeMovementForActor(run.environment.environmentId, actorId)
  if existing ~= nil then
    Errors.raise(
      ScriptErrors.SCRIPT_ACTOR_BUSY,
      "another foreground task already moves this actor",
      { scriptId = run.instance.scriptId, actor = actorId, taskId = existing }
    )
  end
  local taskId = run.scheduler:createTask("movement", {
    actor = actorId,
    sequence = node.movement,
    movementId = node.movementId,
  }, run.instance, run.tick, run.input)
  run.environment:registerMovementTask(taskId)
  return Runtime.OUTCOME_CONTINUE
end

-- Generic blocking ops: dispatch through the task registry. The task types
-- and their implementations land with their owning workstreams (dialogue,
-- movement, audio, fade, warp); an unregistered type is an attributed fault.
local function blockingHandler(taskType)
  return function(node, run)
    return blockOnTask(run, taskType, { node = node })
  end
end

HANDLERS.wait_ticks = function(node, run)
  if node.countdownVariable ~= nil then
    -- Observable countdown mirror: the source command writes the frame count
    -- into the destination variable at execution time (ScrCmd_Wait); write it
    -- now and let the task decrement it on each poll so later reads see the
    -- live countdown.
    local id = Runtime.evaluateValue(node.countdownVariable, run)
    run.services.world:setVar(id, node.ticks)
    return blockOnTask(run, "wait_ticks", { node = node, countdownVariable = id })
  end
  return blockOnTask(run, "wait_ticks", { node = node })
end
HANDLERS.wait_input = function(node, run)
  return blockOnTask(run, "wait_input", { node = node })
end
HANDLERS.wait_input_or_ticks = function(node, run)
  return blockOnTask(run, "wait_input_or_ticks", { node = node })
end
HANDLERS.say = function(node, run)
  requireForeground(run, "say")
  return blockOnTask(run, "dialogue", { node = node })
end
HANDLERS.message = function(node, run)
  requireForeground(run, "message")
  if node.waitForPrint == false then
    if run.services.dialogue then
      run.services.dialogue:openMessage(node)
      run.services.dialogue:startPrint(node.message, node.bindings or {})
    end
    return Runtime.OUTCOME_CONTINUE
  end
  return blockOnTask(run, "dialogue", { node = node })
end
HANDLERS.ask_yes_no = function(node, run)
  requireForeground(run, "ask_yes_no")
  return blockOnTask(run, "ask_yes_no", { node = node })
end
HANDLERS.wait_movement = function(node, run)
  return blockOnTask(run, "movement_barrier", { node = node })
end
HANDLERS.move = function(node, run)
  local actorId = Runtime.requireActor(node.actor, run)
  requireForegroundPlayer(run, actorId)
  return blockOnTask(run, "movement", { node = node, blocking = true })
end
HANDLERS.wait_sound = blockingHandler("sound_wait")
HANDLERS.wait_cry = blockingHandler("sound_wait")
HANDLERS.wait_fanfare = blockingHandler("sound_wait")
HANDLERS.wait_fade = blockingHandler("fade")
HANDLERS.warp = function(node, run)
  requireForeground(run, "warp")
  return blockOnTask(run, "warp", { node = node })
end
HANDLERS.lua = function(node, run)
  return blockOnTask(run, "lua", { node = node })
end
HANDLERS.unsupported = function(node, run)
  Errors.raise(ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE, "reachable unsupported node", {
    scriptId = run.instance.scriptId,
    command = node.command,
    originalName = node.originalName,
    sourceOffset = node.sourceOffset,
  })
end

-- Same-tick audio, camera, dialogue-primitive, and open/close operations:
-- they apply their side effect and continue. The audio/camera/maps services
-- are injected by the game layer; task-backed waits are separate nodes.
local function passthroughOp()
  return function(node, run)
    return Runtime.OUTCOME_CONTINUE
  end
end

-- Same-tick operations that still need services; each is wired when its
-- owning workstream lands. Until then they apply nothing but continue, which
-- is safe because the generated scripts that use them pair them with the
-- blocking wait nodes that are separately implemented.
HANDLERS.play_sound = function(node, run)
  if run.services.audio then
    run.services.audio:play(node.sound)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.stop_sound = function(node, run)
  if run.services.audio then
    run.services.audio:stop(node.sound)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.play_music = function(node, run)
  if run.services.audio then
    run.services.audio:playMusic(node.music)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.stop_music = function(node, run)
  if run.services.audio then
    run.services.audio:stopMusic(node.music)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.reset_music = function(node, run)
  if run.services.audio then
    run.services.audio:resetMusic()
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.temporary_music = function(node, run)
  if run.services.audio then
    run.services.audio:temporaryMusic(node.music)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.play_cry = function(node, run)
  if run.services.audio then
    run.services.audio:playCry(Runtime.evaluateValue(node.species, run), node.form)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.play_fanfare = function(node, run)
  if run.services.audio then
    run.services.audio:playFanfare(node.fanfare)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.fade_screen = function(node, run)
  if run.services.screen then
    run.services.screen:startFade(node)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.fade_music_out = function(node, run)
  if run.services.audio then
    run.services.audio:fadeMusicOut(node)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.fade_music_in = function(node, run)
  if run.services.audio then
    run.services.audio:fadeMusicIn(node)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.shake_camera = function(node, run)
  if run.services.camera then
    run.services.camera:startShake(node)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.set_spawn = function(node, run)
  if run.services.maps then
    run.services.maps:setSpawn(node.spawn)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.open_message = function(node, run)
  if run.services.dialogue then
    run.services.dialogue:openMessage(node)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.close_message = function(node, run)
  if run.services.dialogue then
    run.services.dialogue:close(node.erase ~= false)
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.hold_message = function(node, run)
  if run.services.dialogue then
    run.services.dialogue:hold()
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.show_waiting_icon = function(node, run)
  if run.services.dialogue then
    run.services.dialogue:showWaitingIcon()
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.hide_waiting_icon = function(node, run)
  if run.services.dialogue then
    run.services.dialogue:hideWaitingIcon()
  end
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.resolve_common_message_bank = passthroughOp()

-- Execute one graph node against the run state. The outcome is one of the
-- outcome constants; a blocking node records its task id in run.blockTaskId.
---@param node table
---@param run table
---@return string
function Runtime.executeNode(node, run)
  run.node = node
  local handler = assert(HANDLERS[node.op], "no runtime handler for op " .. tostring(node.op))
  return handler(node, run)
end

-- The run loop calls this when a linear tail has no successor node: a
-- composition frame advances to the next chain entry, a call frame behaves
-- like `return`, and a plain script tail completes the instance.
---@param run table
---@return string
function Runtime.fallOffEnd(run)
  local instance = run.instance
  local frame = instance:topFrame()
  if frame.composition ~= nil and frame.chain ~= nil then
    return advanceChain(run, frame)
  end
  if frame.returnNodeId ~= nil then
    local popped = instance:popFrame()
    instance:resumeCaller(popped)
    return Runtime.OUTCOME_CONTINUE
  end
  return Runtime.OUTCOME_STOP
end

return Runtime
