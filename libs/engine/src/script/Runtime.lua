-- Internal graph node execution: the runtime executes compiled graphs, never
-- authoring tables. Every node handler returns exactly one outcome:
-- `continue`, `yield_tick`, `block`, or `stop`. Attributed faults (missing
-- actors, background-forbidden operations, lock violations, task failures)
-- raise Errors objects that the scheduler's run loop converts into faulted
-- instances. Value and condition evaluation also live here because task
-- implementations share them. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local ScriptEnvironment = require("libs.engine.src.script.ScriptEnvironment")
local FieldWindowStyles = require("libs.engine.src.FieldWindowStyles")
local MovementPauseTask = require("libs.engine.src.script.tasks.MovementPauseTask")
local MovementTask = require("libs.engine.src.script.tasks.MovementTask")

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
    local flagId = Runtime.resolveIdOperand(v.flag, run)
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

-- Resolve an id_or_var operand to the world id it names. A variable
-- reference names its own variable (the translator emits var refs for
-- var-range operands, e.g. copy_var/set_var, and the source operand IS the
-- variable id); every other form evaluates as before (a direct string or
-- numeric id passes through, local/arg references dereference).
---@param v any
---@param run table
---@return any
function Runtime.resolveIdOperand(v, run)
  if type(v) == "table" and v.value == "var" then
    return v.id
  end
  return Runtime.evaluateValue(v, run)
end

-- Resolve a semantic message descriptor before it crosses into a host. This
-- keeps dynamic operands and gender selection in the runtime, while the
-- dialogue/menu hosts retain one concrete-message resolution contract.
---@param message any
---@param run table
---@return any
function Runtime.evaluateMessage(message, run)
  if type(message) ~= "table" then
    return message
  end
  if message.value ~= nil then
    return Runtime.evaluateValue(message, run)
  end
  if message.message == "external" then
    return {
      message = "external",
      bank = Runtime.evaluateValue(message.bank, run),
      id = Runtime.evaluateValue(message.id, run),
    }
  end
  if message.text == "gendered_message" then
    local gender = run.services.player:gender()
    return Runtime.evaluateMessage(gender == 0 and message.male or message.female, run)
  end
  Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "unknown message reference form", { message = message })
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
    local flagId = Runtime.resolveIdOperand(condition.id, run)
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
    -- MapObjectManager_GetFirstActiveObjectByID path). The actor world
    -- contract requires actorIdForMapIndex.
    local actorId = run.services.actors:actorIdForMapIndex(ref.mapIndex)
    if actorId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
        "map object index " .. tostring(ref.mapIndex) .. " does not resolve in the current map",
        { scriptId = run.instance.scriptId, mapIndex = ref.mapIndex }
      )
    end
    return actorId --[[@as string]]
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
      actorId = run.services.actors:cameraTargetId()
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

local function requireScriptMenu(run)
  local host = run.services.scriptMenu
  if host == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "scriptMenu service is unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  return host
end

-- Create a blocking task through the scheduler and return the block outcome.
-- The blocking node's `result` ref (ask_yes_no) rides along so the
-- scheduler can write the completed task result on continuation.
---@param run table
---@param taskType string
---@param spec table
---@param resultRef table|nil
local function blockOnTask(run, taskType, spec, resultRef)
  local taskId = run.scheduler:createTask(taskType, spec, run.instance, run.tick, run.input)
  run.blockTaskId = taskId
  run.blockResultRef = resultRef or (run.node and run.node.result or nil)
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
  return entry.graph, nodeId --[[@as string]]
end

-- Resolve a call target through the scheduler's composition resolver; a
-- missing target is an attributed call error.
---@param run table
---@param target string
---@return table composed
local function resolveCallTarget(run, target)
  local composed = run.scheduler:resolveComposition(target)
  if composed == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_CALL_TARGET_MISSING,
      "no composed script for call target " .. target,
      { scriptId = run.instance.scriptId, target = target }
    )
  end
  return composed --[[@as table]]
end

-- --- Node handlers ------------------------------------------------------------

-- Same-tick audio, camera, dialogue-primitive, and open/close operations:
-- they apply their side effect and continue. A missing service is an
-- attributed fault, never a silent skip: the platform must not count an
-- unsupported operation as successfully executed.
local function requireService(run, name)
  local service = run.services[name]
  if service == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      name .. " service is unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  return service
end

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

-- ScrCmd_061 (std_signpost's hide-branch tail): no operands. The source
-- installs the Start Menu reopen end callback (sub_0204031C ->
-- sub_0203BD64) and returns FALSE, ending the script context. The reopen
-- request routes through the startMenuReopen service, which the Start Menu
-- application host consumes when the environment ends; a missing
-- service is an attributed fault, never a silent close. The STOP outcome
-- ends this script context (a child context ending resumes the caller
-- through the child-slot mechanics).
HANDLERS.request_start_menu = function(node, run)
  requireService(run, "startMenuReopen"):request()
  return Runtime.OUTCOME_STOP
end

HANDLERS.yield_tick = function(node, run)
  return Runtime.OUTCOME_YIELD_TICK
end

HANDLERS.set_auxiliary_ui_visible = function(node, run)
  requireForeground(run, "set_auxiliary_ui_visible")
  local auxiliary = run.services.auxiliaryUi
  if auxiliary == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "auxiliaryUi service is unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  assert(auxiliary, "auxiliaryUi service is unavailable")
  if not node.visible and auxiliary:status().state == "hidden" then
    return Runtime.OUTCOME_CONTINUE
  end
  return blockOnTask(run, "auxiliary_ui", { node = node })
end

HANDLERS.context_choice = function(node, run)
  requireForeground(run, "context_choice")
  if run.services.contextChoice == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "contextChoice service is unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  return blockOnTask(run, "context_choice", { node = node })
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
  -- The value is evaluated against the callee frame (its own args), so it
  -- must be resolved before the frame is popped.
  local value
  if node.value ~= nil then
    value = Runtime.evaluateValue(node.value, run)
  end
  local frame = run.instance:popFrame()
  assert(frame ~= nil, "return with an empty frame stack")
  if value ~= nil then
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

-- The source `ScrCmd_RestartCurrentScript` (opcode 21) toggles the caller
-- signal bit and returns FALSE: the common-child context ENDS at the
-- signal — it never falls through to the instructions after signal_caller
-- (std_signpost's hide branch is reachable only through its goto targets).
-- The stop outcome ends the child; the caller's child_script task observes
-- the signal on its next poll.
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
  return Runtime.OUTCOME_STOP
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
  local flagId = Runtime.resolveIdOperand(node.flag, run)
  run.services.world:setFlag(flagId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.clear_flag = function(node, run)
  local flagId = Runtime.resolveIdOperand(node.flag, run)
  run.services.world:clearFlag(flagId)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.set_var = function(node, run)
  local variableId = Runtime.resolveIdOperand(node.variable, run)
  local value = Runtime.evaluateValue(node.value, run)
  run.services.world:setVar(variableId, value)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.copy_var = function(node, run)
  local destination = Runtime.resolveIdOperand(node.destination, run)
  local source = Runtime.resolveIdOperand(node.source, run)
  run.services.world:setVar(destination, run.services.world:getVar(source))
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.add_var = function(node, run)
  local variableId = Runtime.resolveIdOperand(node.variable, run)
  local amount = Runtime.evaluateValue(node.amount, run)
  run.services.world:addVar(variableId, amount)
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.sub_var = function(node, run)
  local variableId = Runtime.resolveIdOperand(node.variable, run)
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
    return blockOnTask(run, MovementPauseTask.type, {})
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
  if node.waitUntilPausable then
    -- The pause task watches the actor's movement and completes when the
    -- actor is at a pausable boundary (or is not moving at all).
    return blockOnTask(run, MovementPauseTask.actorType, { actor = actorId })
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
    fieldX = Runtime.evaluateValue(node.fieldX, run),
    fieldZ = Runtime.evaluateValue(node.fieldZ, run),
    worldY = Runtime.evaluateValue(node.worldY, run),
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

-- The single movement-start path shared by the asynchronous
-- (`apply_movement`) and blocking (`move`) forms: resolve the actor,
-- enforce foreground-player and actor-busy ownership, create the task, and
-- register it in the environment's movement generation so barriers and
-- pause logic observe it. The blocking form records the task id and returns
-- the block outcome. Completion cleanup for both forms lives in the task's
-- poll: the nonblocking form completes through the scheduler, the blocking
-- form unregisters before reporting its completion result.
---@param run table
---@param node table
---@param blocking boolean
---@return string outcome
local function startMovement(run, node, blocking)
  local actorId = Runtime.requireActor(node.actor, run)
  requireForegroundPlayer(run, actorId)
  -- The actor-busy check and the movement-generation registration are owned
  -- by the task-creation boundary (MovementTask.create + Scheduler:createTask),
  -- so both the blocking and nonblocking move forms share them.
  local taskId = run.scheduler:createTask(MovementTask.type, {
    actor = actorId,
    sequence = node.movement,
    movementId = node.movementId,
    blocking = blocking,
  }, run.instance, run.tick, run.input)
  if blocking then
    run.blockTaskId = taskId
    return Runtime.OUTCOME_BLOCK
  end
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.apply_movement = function(node, run)
  return startMovement(run, node, false)
end

-- Generic blocking ops: dispatch through the task registry. The task types
-- and their implementations land with their owning task modules (dialogue,
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
    local id = Runtime.resolveIdOperand(node.countdownVariable, run)
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
    -- Nonblocking print: open and start the printer same tick, then continue.
    -- A missing dialogue service is an attributed fault, never a silent skip,
    -- and the instance's buffered text args ride alongside node bindings
    -- exactly as on the blocking DialogueTask path.
    local host = requireService(run, "dialogue")
    -- LuaLS cannot see through Errors.raise; requireService never returns nil.
    ---@cast host table
    host:openMessage(node)
    host:startPrint(node.message, node.bindings or {}, run.instance.textArgs or {})
    return Runtime.OUTCOME_CONTINUE
  end
  return blockOnTask(run, "dialogue", { node = node })
end
HANDLERS.ask_yes_no = function(node, run)
  requireForeground(run, "ask_yes_no")
  return blockOnTask(run, "ask_yes_no", { node = node })
end
HANDLERS.choose = function(node, run)
  requireForeground(run, "choose")
  local items = {}
  for luaIndex, item in ipairs(node.items) do
    items[luaIndex] = {
      text = Runtime.evaluateMessage(item.text, run),
      value = Runtime.evaluateValue(item.value, run),
      metadata = item.metadata,
    }
  end
  local cancelValue = nil
  if node.cancelValue ~= nil then
    cancelValue = Runtime.evaluateValue(node.cancelValue, run)
  end
  local request = requireScriptMenu(run):choose({
    items = items,
    cancellable = node.cancellable,
    cancelValue = cancelValue,
    initialCursor = node.initialCursor,
    placement = node.placement,
    result = node.result,
  })
  assert(type(request) == "table" and type(request.items) == "table", "script menu host returned an invalid request")
  return blockOnTask(run, "menu", { menu = request }, request.result)
end
HANDLERS.menu_begin = function(node, run)
  requireForeground(run, "menu_begin")
  if run.instance.menuBuilder ~= nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_ALREADY_BUILDING, "a script menu is already being built")
  end
  run.instance.menuBuilder = requireScriptMenu(run):beginMenu({
    messageSource = node.messageSource,
    sourcePlacement = node.sourcePlacement,
    initialCursor = node.initialCursor,
    cancellable = node.cancellable,
    result = node.result,
  })
  return Runtime.OUTCOME_YIELD_TICK
end
HANDLERS.menu_add = function(node, run)
  requireForeground(run, "menu_add")
  requireScriptMenu(run):addItem(run.instance.menuBuilder, {
    messageId = Runtime.evaluateValue(node.messageId, run),
    vanillaMetadata = Runtime.evaluateValue(node.vanillaMetadata, run),
    value = Runtime.evaluateValue(node.value, run),
  })
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.menu_exec = function(_, run)
  requireForeground(run, "menu_exec")
  local request = requireScriptMenu(run):execute(run.instance.menuBuilder)
  assert(type(request) == "table" and type(request.items) == "table", "script menu host returned an invalid request")
  run.instance.menuBuilder = nil
  return blockOnTask(run, "menu", { menu = request }, request.result)
end
HANDLERS.wait_movement = function(node, run)
  return blockOnTask(run, "movement_barrier", { node = node })
end
HANDLERS.move = function(node, run)
  return startMovement(run, node, true)
end
HANDLERS.wait_sound = blockingHandler("sound_wait")
HANDLERS.wait_cry = blockingHandler("sound_wait")
HANDLERS.wait_fanfare = blockingHandler("sound_wait")
HANDLERS.wait_fade = blockingHandler("fade")
HANDLERS.warp = function(node, run)
  requireForeground(run, "warp")
  return blockOnTask(run, "warp", { node = node })
end

HANDLERS.unsupported = function(node, run)
  Errors.raise(ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE, "reachable unsupported node", {
    scriptId = run.instance.scriptId,
    command = node.command,
    originalName = node.originalName,
    sourceOffset = node.sourceOffset,
  })
end

HANDLERS.play_sound = function(node, run)
  requireService(run, "audio"):play(Runtime.evaluateValue(node.sound, run))
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.stop_sound = function(node, run)
  requireService(run, "audio"):stop(Runtime.evaluateValue(node.sound, run))
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.play_music = function(node, run)
  requireService(run, "audio"):playMusic(node.music)
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.stop_music = function(node, run)
  -- The pinned StopBGM reads its operand but ignores it: the currently
  -- playing BGM stops, and the operand never reaches the service.
  requireService(run, "audio"):stopMusic()
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.reset_music = function(node, run)
  requireService(run, "audio"):resetMusic()
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.temporary_music = function(node, run)
  requireService(run, "audio"):temporaryMusic(node.music)
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.play_cry = function(node, run)
  requireService(run, "audio"):playCry(Runtime.evaluateValue(node.species, run), Runtime.evaluateValue(node.form, run))
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.play_fanfare = function(node, run)
  requireService(run, "audio"):playFanfare(Runtime.evaluateValue(node.fanfare, run))
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.fade_screen = function(node, run)
  requireService(run, "screen"):startFade(node)
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.fade_music_out = function(node, run)
  -- The fade node starts the fade in its execution tick and blocks until
  -- the audio service reports the global music fade inactive (the source
  -- command's combined start-and-native-wait semantics).
  return blockOnTask(run, "music_fade", { node = node })
end
HANDLERS.fade_music_in = function(node, run)
  return blockOnTask(run, "music_fade", { node = node })
end
HANDLERS.shake_camera = function(node, run)
  requireService(run, "camera"):startShake(node)
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.set_spawn = function(node, run)
  requireService(run, "maps"):setSpawn(node.spawn)
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.open_message = function(node, run)
  requireService(run, "dialogue"):openMessage(node)
  return Runtime.OUTCOME_CONTINUE
end

-- DirectionSignpost (55): store the source appearance, select SHOW and
-- execute it in-handler exactly like the source command's inline
-- Signpost_DoCurrentCommand call, then read/expand and print the message
-- instantly in the signpost window. The unused out operand is never written.
-- Yields one tick (the source returns TRUE without installing a waiter).
HANDLERS.signpost_direction = function(node, run)
  requireForeground(run, "signpost_direction")
  local host = requireService(run, "signpost")
  -- LuaLS cannot see through Errors.raise; requireService never returns nil.
  ---@cast host ScriptSignpostHost
  host:setSourceAppearance(node.sourceAppearance)
  host:setCommand("show")
  host:advance()
  host:printInstant(node.message, nil, run.instance.textArgs or {})
  return Runtime.OUTCOME_YIELD_TICK
end

-- SetSignpostMap (56): store the source appearance and queue SHOW without
-- executing it (the field signpost update runs the queued command later).
-- Yields one tick.
HANDLERS.signpost_set = function(node, run)
  requireForeground(run, "signpost_set")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  host:setSourceAppearance(node.sourceAppearance)
  host:setCommand("show")
  return Runtime.OUTCOME_YIELD_TICK
end

-- SetSignpostAction (57): assign the semantic command to the signpost
-- window. Signpost_SetCommand is a bare assignment with no busy guard, so a
-- running action is superseded; the fixed-tick controller executes it at the
-- next field update (never in-handler) and returns the command to nop when
-- the action completes. Yields one tick.
HANDLERS.signpost_command = function(node, run)
  requireForeground(run, "signpost_command")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  host:setCommand(node.command)
  return Runtime.OUTCOME_YIELD_TICK
end

-- WaitSignpostAction (58): block until the signpost command is idle. On
-- entry the command may already be idle (the source returns immediately), in
-- which case the script continues in the same tick; otherwise a registered
-- task polls the host's semantic idle query each tick and completes only
-- when the command is idle again. Opcode 58 has no result operand, so no
-- result reference rides along.
HANDLERS.wait_signpost_action = function(node, run)
  requireForeground(run, "wait_signpost_action")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  if host:isCommandIdle() then
    return Runtime.OUTCOME_CONTINUE
  end
  return blockOnTask(run, "wait_signpost_action", {})
end

-- TrainerTips (59): print the resolved message into the existing signpost
-- window at the player's configured text speed and block on the registered
-- task. The task owns the source input semantics (directional interrupt
-- stops the printer, turns the player, and completes 0; A/B fills the
-- print and completes 2; normal completion writes 2 through the scheduler
-- result reference) and never writes world variables directly.
HANDLERS.trainer_tips_print = function(node, run)
  requireForeground(run, "trainer_tips_print")
  requireService(run, "signpost")
  return blockOnTask(run, "trainer_tips_print", { node = node })
end

-- WaitSignpost (60): always install a waiter for the A/B/directional
-- dismissal of the presented signpost window. The task completes 0 through
-- the scheduler result reference on any dismissal edge.
HANDLERS.wait_signpost = function(node, run)
  requireForeground(run, "wait_signpost")
  requireService(run, "signpost")
  return blockOnTask(run, "wait_signpost", { node = node })
end

-- The high-level sign ops route their requested appearance (a semantic
-- value or a catalogued style id) through the window style catalogue
-- service: the style id is stamped into the controller, and a style that
-- does not exist is an attributed script fault, never a presentation crash
-- at draw time.
---@param run table
---@param appearance string
---@return string styleId
local function resolveSignpostStyle(run, appearance)
  local styles = requireService(run, "windowStyles")
  -- LuaLS cannot see through Errors.raise; requireService never returns nil.
  ---@cast styles FieldWindowStyles
  local styleId = FieldWindowStyles.semanticStyleId(appearance) or appearance
  if styles:resolve(styleId) == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_STYLE_UNKNOWN,
      "window style is not registered: " .. tostring(styleId),
      { scriptId = run.instance.scriptId, styleId = styleId }
    )
  end
  return styleId
end

-- The high-level S.sign operation: present the signpost window with the
-- requested style id (no source type/map data), print the message
-- instantly, and block on the registered sign task until an A/B or
-- directional dismissal closes the window. The open composes the same
-- host/controller primitives the imported operations use; the sign task
-- owns the complete open -> dismiss -> close lifecycle, so the sign is
-- always blocking.
HANDLERS.sign = function(node, run)
  requireForeground(run, "sign")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  host:setStyleId(resolveSignpostStyle(run, node.appearance))
  host:setCommand("show")
  host:advance()
  host:printInstant(node.message, nil, run.instance.textArgs or {})
  return blockOnTask(run, "sign", { node = node })
end

-- The high-level S.trainerTip operation: present the signpost window with
-- the requested style id, type the message at the player's configured text
-- speed, and block on the registered sign task. The task waits for the
-- print and then for an A/B/directional dismissal; a direction pressed
-- while the print is live is the source interruption (printer stops, player
-- turns, window closes).
HANDLERS.trainer_tip = function(node, run)
  requireForeground(run, "trainer_tip")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  host:setStyleId(resolveSignpostStyle(run, node.appearance))
  host:setCommand("show")
  host:advance()
  host:printTyped(node.message, nil, run.instance.textArgs or {})
  return blockOnTask(run, "sign", { node = node })
end
HANDLERS.close_message = function(node, run)
  requireService(run, "dialogue"):close(node.erase ~= false)
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.hold_message = function(node, run)
  requireService(run, "dialogue"):hold()
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.show_waiting_icon = function(node, run)
  requireService(run, "dialogue"):showWaitingIcon()
  return Runtime.OUTCOME_CONTINUE
end
HANDLERS.hide_waiting_icon = function(node, run)
  requireService(run, "dialogue"):hideWaitingIcon()
  return Runtime.OUTCOME_CONTINUE
end

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
