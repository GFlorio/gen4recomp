-- The authoritative fixed-tick field-script scheduler . One step per field tick implements the source-derived order: advance
-- engine-owned asynchronous work, poll eligible tasks once in deterministic
-- creation order (a task never polls in its creation tick; a completing task
-- marks its owner `resume_pending` for the next tick), promote older
-- `resume_pending` contexts, run every ready context to yield (at most once
-- per tick, visiting environment context slots 0..2 dynamically so a later
-- common child can start in the caller's tick), then resolve at most one new
-- foreground interaction trigger. Node outcomes are the internal contract of
-- section 2; the per-run node budget faults instead of injecting delays.
-- Cancellation follows section 26.10. Pure domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local Runtime = require("libs.engine.src.script.Runtime")
local ScriptInstance = require("libs.engine.src.script.ScriptInstance")
local ScriptEnvironment = require("libs.engine.src.script.ScriptEnvironment")
local ScriptTask = require("libs.engine.src.script.ScriptTask")

---@class SchedulerServices
---@field world table
---@field actors table
---@field player table
---@field dialogue table|nil
---@field audio table|nil
---@field camera table|nil
---@field maps table|nil
---@field screen table|nil
---@field events table|nil
---@field advanceAsync fun(tick: integer)|nil
---@field foreground table|nil { resolve(input) -> {trigger, composed}|nil }

---@class Scheduler
---@field private _services SchedulerServices
---@field private _taskRegistry TaskRegistry
---@field private _traceSink fun(record: table)|nil
---@field private _resolveComposition fun(scriptId: string): table|nil
---@field private _maxNodes integer
---@field private _environments table<string, ScriptEnvironment>
---@field private _backgrounds ScriptEnvironment[]
---@field private _foregroundEnvironmentId string|nil
---@field private _instances table<string, ScriptInstance>
---@field private _tasks ScriptTask[]
---@field private _tasksById table<string, ScriptTask>
---@field private _nextEnvironmentId integer
---@field private _nextInstanceId integer
---@field private _nextTaskId integer
local Scheduler = {}
Scheduler.__index = Scheduler

-- Run-phase safety budget : a context that cannot yield
-- faults with SCRIPT_STEP_BUDGET_EXCEEDED; the runtime never converts budget
-- exhaustion into an implicit yield.
Scheduler.MAX_NONBLOCKING_NODES_PER_TICK = 1024

---@param opts table
---@return Scheduler
function Scheduler.new(opts)
  assert(opts and opts.services, "scheduler services required")
  assert(opts.taskRegistry, "scheduler task registry required")
  return setmetatable({
    _services = opts.services,
    _taskRegistry = opts.taskRegistry,
    _traceSink = opts.trace,
    _resolveComposition = opts.resolveComposition,
    _maxNodes = opts.maxNonBlockingNodesPerTick or Scheduler.MAX_NONBLOCKING_NODES_PER_TICK,
    _environments = {},
    _backgrounds = {},
    _foregroundEnvironmentId = nil,
    _instances = {},
    _tasks = {},
    _tasksById = {},
    _nextEnvironmentId = 0,
    _nextInstanceId = 0,
    _nextTaskId = 0,
  }, Scheduler)
end

-- --- Diagnostics -------------------------------------------------------------

function Scheduler:_trace(kind, fields)
  if self._traceSink == nil then
    return
  end
  fields = fields or {}
  fields.tick = fields.tick or self._currentTick
  fields.kind = kind
  self._traceSink(fields)
end

function Scheduler:_emit(name, payload)
  local events = self._services.events
  if events and events.emit then
    events:emit(name, payload)
  end
end

-- --- Composition resolution ---------------------------------------------------

-- Resolve a public script id to its effective composed chain; the game layer
-- wires this to the registry/composition pair (WS7). Unknown ids resolve to
-- nil and produce attributed call errors.
---@param scriptId string
---@return table|nil
function Scheduler:resolveComposition(scriptId)
  if self._resolveComposition == nil then
    return nil
  end
  return self._resolveComposition(scriptId)
end

-- --- Instance and environment creation ---------------------------------------

local function environmentIdFor(self)
  self._nextEnvironmentId = self._nextEnvironmentId + 1
  return string.format("script-env-%08d", self._nextEnvironmentId)
end

local function instanceIdFor(self)
  self._nextInstanceId = self._nextInstanceId + 1
  return string.format("script-%08d", self._nextInstanceId)
end

local function taskIdFor(self)
  self._nextTaskId = self._nextTaskId + 1
  return string.format("task-%08d", self._nextTaskId)
end

-- Push the entry frame of a composed chain onto a fresh instance.
---@param instance ScriptInstance
---@param composed table
---@param args table
local function pushEntryFrame(instance, composed, args)
  local entries = composed.entries
  assert(#entries > 0, "composed script has no entries")
  local entry = entries[1]
  instance:pushFrame(instance:makeFrame(entry.graph, entry.graph.entry, {
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

---@param env ScriptEnvironment
---@param composed table
---@param trigger table|nil
---@param args table|nil
---@param tick integer
---@return ScriptInstance
function Scheduler:_createInstance(env, composed, trigger, args, tick)
  local instance = ScriptInstance.new({
    instanceId = instanceIdFor(self),
    environmentId = env.environmentId,
    contextSlot = 0,
    scriptId = composed.scriptId,
    revision = composed.revision,
    owner = composed.entries[1].owner,
    mode = env.mode,
    trigger = trigger,
    args = args or {},
    createdAtTick = tick,
    readyAtTick = tick,
  })
  pushEntryFrame(instance, composed, instance.args)
  self._instances[instance.instanceId] = instance
  self:_emit("script.started", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    mode = instance.mode,
    trigger = instance.trigger,
    revision = instance.revision,
  })
  return instance
end

-- Create an execution environment whose root is a fresh instance of a
-- composed script . Foreground environments
-- register as the field owner; background environments join the creation
-- order. The new context may run in this tick; the caller decides whether
-- the slot loop visits it now.
---@param mode string
---@param composed table
---@param trigger table|nil
---@param tick integer
---@return string instanceId
function Scheduler:_createEnvironment(mode, composed, trigger, tick)
  local env = ScriptEnvironment.new({
    environmentId = environmentIdFor(self),
    mode = mode,
    createdAtTick = tick,
  })
  self._environments[env.environmentId] = env
  if mode == "foreground" then
    self._foregroundEnvironmentId = env.environmentId
  else
    self._backgrounds[#self._backgrounds + 1] = env
  end
  local instance = self:_createInstance(env, composed, trigger, nil, tick)
  env:setRoot(instance.instanceId)
  self:_trace("environment_created", {
    environmentId = env.environmentId,
    mode = mode,
    instanceId = instance.instanceId,
  })
  return instance.instanceId
end

-- Start a foreground interaction: a fresh environment whose root owns the
-- field . The new context may run in this tick; the
-- caller decides whether the slot loop visits it now.
---@param composed table
---@param trigger table|nil
---@param tick integer
---@return string instanceId
function Scheduler:createForeground(composed, trigger, tick)
  assert(self._foregroundEnvironmentId == nil, "a foreground environment already owns the field")
  return self:_createEnvironment("foreground", composed, trigger, tick)
end

-- Start a project-native background environment .
-- Background environments run after the foreground environment in creation
-- order and may not use foreground-only operations.
---@param composed table
---@param trigger table|nil
---@param tick integer
---@return string instanceId
function Scheduler:createBackground(composed, trigger, tick)
  return self:_createEnvironment("background", composed, trigger, tick)
end

-- Create a verified common-script child context in a later slot of the
-- caller's environment . The child is ready for the
-- current tick; the dynamic slot loop decides whether it runs now. `args`
-- are already evaluated call arguments.
---@param composed table
---@param args table
---@param run table
---@param slot integer
---@return ScriptInstance
function Scheduler:createChildInstance(composed, args, run, slot)
  local child = ScriptInstance.new({
    instanceId = instanceIdFor(self),
    environmentId = run.environment.environmentId,
    contextSlot = slot,
    scriptId = composed.scriptId,
    revision = composed.revision,
    owner = composed.entries[1].owner,
    mode = run.environment.mode,
    trigger = run.instance.trigger,
    args = args,
    createdAtTick = run.tick,
    readyAtTick = run.tick,
  })
  pushEntryFrame(child, composed, args)
  self._instances[child.instanceId] = child
  run.environment:placeContext(slot, child.instanceId)
  self:_emit("script.started", {
    scriptId = child.scriptId,
    instanceId = child.instanceId,
    owner = child.owner,
    mode = child.mode,
    trigger = child.trigger,
    revision = child.revision,
  })
  self:_trace("child_created", {
    instanceId = child.instanceId,
    environmentId = child.environmentId,
    slot = slot,
  })
  return child
end

-- Allocate the lowest free later slot, create the common child, and arm the
-- caller signal . Shared by the call_common node and the
-- raw `ctx.script:call` descriptor.
---@param composed table
---@param args table
---@param run table
---@return ScriptInstance child, integer slot, integer parentSlot
function Scheduler:createCommonChild(composed, args, run)
  local parentSlot = run.instance.contextSlot
  local slot = run.environment:freeChildSlot(parentSlot)
  if slot == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_CONTEXT_SLOTS_EXHAUSTED,
      "script environment has no free context slot",
      { scriptId = run.instance.scriptId, environmentId = run.environment.environmentId }
    )
  end
  slot = slot --[[@as integer]]
  local child = self:createChildInstance(composed, args, run, slot)
  run.environment:setCallerSignal(parentSlot, true)
  return child,
    slot, --[[@as integer]]
    parentSlot
end

-- --- Task creation ------------------------------------------------------------

-- The shared execution envelope passed to task implementations (poll/create)
-- and to Runtime node handlers: the scheduler, the owning instance and
-- environment, the current fixed tick, the immutable input snapshot, and the
-- injected services.
---@param instance ScriptInstance
---@param environment ScriptEnvironment
---@param tick integer
---@param input table|nil
---@return table
function Scheduler:_ctxFor(instance, environment, tick, input)
  return {
    scheduler = self,
    instance = instance,
    environment = environment,
    tick = tick,
    input = input,
    services = self._services,
  }
end

-- Create a blocking or owner task through the registry .
-- The record's first poll is always the next tick: a task created during
-- this tick is never eligible in it.
---@param taskType string
---@param spec table
---@param instance ScriptInstance
---@param tick integer
---@param input table|nil
---@return string taskId
function Scheduler:createTask(taskType, spec, instance, tick, input)
  local impl, resolveErr = self._taskRegistry:resolve(taskType, 1)
  if not impl then
    local err = resolveErr --[[@as Errors.Error]]
    Errors.raise(
      err.code,
      err.message,
      { scriptId = instance.scriptId, instanceId = instance.instanceId, taskType = taskType, cause = err }
    )
  end
  impl = impl --[[@as table]]
  local environment = assert(self._environments[instance.environmentId], "task owner environment missing")
  local ctx = self:_ctxFor(instance, environment, tick, input)
  local state = impl.create(spec, ctx)
  local task = ScriptTask.new({
    taskId = taskIdFor(self),
    taskType = taskType,
    taskVersion = impl.version,
    ownerInstanceId = instance.instanceId,
    environmentId = environment.environmentId,
    createdAtTick = tick,
    pollAtTick = tick + 1,
    state = state,
  })
  self._tasks[#self._tasks + 1] = task
  self._tasksById[task.taskId] = task
  self:_emit("script.task_started", {
    taskId = task.taskId,
    taskType = taskType,
    taskVersion = task.taskVersion,
    instanceId = instance.instanceId,
    createdAtTick = tick,
  })
  self:_trace("task_created", {
    taskId = task.taskId,
    taskType = taskType,
    instanceId = instance.instanceId,
  })
  return task.taskId
end

-- Mark an engine-owned movement task complete (used by the actor world when
-- scripted movement finishes; ). Removes it from the
-- environment's current generation so barriers observe the predicate change.
---@param taskId string
---@param tick integer
function Scheduler:completeMovementTask(taskId, tick)
  local task = self._tasksById[taskId]
  if task == nil or task.status ~= "active" then
    return
  end
  local environment = self._environments[task.environmentId]
  if environment then
    environment:unregisterMovementTask(taskId)
  end
  task:complete(tick, nil)
end

-- --- Tick ---------------------------------------------------------------------

-- The authoritative per-tick step . `input` is the
-- immutable fixed-tick input snapshot; it is shared by trigger resolution and
-- input-wait tasks and never replayed.
---@param tick integer
---@param input table|nil
function Scheduler:step(tick, input)
  assert(self._currentTick == nil or tick > self._currentTick, "scheduler ticks must advance monotonically")
  self._currentTick = tick
  self._currentInput = input
  local advance = self._services.advanceAsync
  if advance then
    advance(tick)
  end
  -- Contexts already in resume_pending before this tick :
  -- a task that completes during this tick must never promote in it.
  local pendingSnapshot = self:_resumePendingSnapshot()
  self:_pollTasks(tick)
  self:_promoteResumePending(tick, pendingSnapshot)
  self:_runEnvironments(tick, input)
  self:_resolveInteraction(tick, input)
end

function Scheduler:_resumePendingSnapshot()
  local out = {}
  for instanceId, instance in pairs(self._instances) do
    if instance.status == "resume_pending" then
      out[#out + 1] = instanceId
    end
  end
  table.sort(out)
  return out
end

-- Poll every active task at most once per tick, in deterministic creation
-- order . A completing task marks its owner
-- `resume_pending` with `readyAtTick = tick + 1`; graph continuation never
-- happens in the completion tick.
function Scheduler:_pollTasks(tick)
  for _, task in ipairs(self._tasks) do
    if task:isPollEligible(tick) then
      assert(task.lastPolledTick ~= tick, "task double-polled in one tick")
      local owner = self._instances[task.ownerInstanceId]
      assert(owner, "task owner instance missing")
      local environment = assert(self._environments[task.environmentId], "task environment missing")
      local impl = assert(self._taskRegistry:resolve(task.taskType, task.taskVersion))
      task.lastPolledTick = tick
      local ctx = self:_ctxFor(owner, environment, tick, self._currentInput)
      ctx.taskId = task.taskId
      local result = impl.poll(task.state, ctx)

      task.state = result.state
      self:_trace("task_polled", {
        taskId = task.taskId,
        taskType = task.taskType,
        instanceId = owner.instanceId,
        complete = result.complete == true,
      })
      if result.complete then
        task:complete(tick, result.result)
        if impl.onComplete then
          impl.onComplete(task.state, ctx)
        end
        self:_emit("script.task_ended", {
          taskId = task.taskId,
          taskType = task.taskType,
          instanceId = owner.instanceId,
          completedAtTick = tick,
          result = result.result,
        })
        local termination = type(result.result) == "table" and result.result.termination or nil
        if termination == "faulted" then
          -- A common child fault propagates to its blocked parent through the
          -- child_script task : the parent faults with the
          -- child's attributed error.
          self:_faultInstance(
            owner,
            tick,
            result.result.error
              or Errors.new(ScriptErrors.SCRIPT_CALLER_SIGNAL_INVALID, "common child faulted", {
                scriptId = owner.scriptId,
                instanceId = owner.instanceId,
              })
          )
        else
          owner.status = "resume_pending"
          owner.readyAtTick = tick + 1
          owner.taskResult = result.result
        end
      end
    end
  end
end

-- Write a completed task result into the blocking node's result reference
-- (ask_yes_no, lua; ). The ref is evaluated
-- against the instance on the promotion tick.
function Scheduler:_writeTaskResult(instance)
  local run = {
    instance = instance,
    node = { nodeId = "<task-result>" },
    services = self._services,
  }
  Runtime.writeRef(instance.pendingResultRef, instance.taskResult, run)
end

-- Promote contexts that were already `resume_pending` before this tick and
-- whose ready deadline has arrived: consume the completed task result exactly
-- once and drop the consumed task record .
---@param tick integer
---@param pendingSnapshot string[]
function Scheduler:_promoteResumePending(tick, pendingSnapshot)
  for _, instanceId in ipairs(pendingSnapshot) do
    local instance = self._instances[instanceId]
    if instance ~= nil and instance.status == "resume_pending" and instance.readyAtTick <= tick then
      instance.status = "ready"
      instance.yieldReason = nil
      local task = self._tasksById[instance.waitingTaskId]
      if task then
        self._tasksById[task.taskId] = nil
        task:markConsumed()
      end
      instance.waitingTaskId = nil
      if instance.pendingResultRef ~= nil and instance.taskResult ~= nil then
        self:_writeTaskResult(instance)
      end
      instance.pendingResultRef = nil
      self:_trace("resume_promoted", { instanceId = instanceId })
    end
  end
end

-- Visit every execution environment in deterministic order (the foreground
-- environment first, then background environments in creation order) and run
-- each eligible context in its slot once . The slot loop
-- is dynamic: a common child created by an earlier slot runs in this tick.
function Scheduler:_runEnvironments(tick, input)
  for _, env in ipairs(self:_orderedEnvironments()) do
    self:_runEnvironmentSlots(env, tick, input)
  end
end

function Scheduler:_runEnvironmentSlots(env, tick, input)
  for slot = 0, ScriptEnvironment.SLOT_COUNT - 1 do
    local instanceId = env:contextAt(slot)
    if instanceId ~= nil then
      local instance = assert(self._instances[instanceId], "context references a missing instance")
      if instance.status == "ready" and instance.readyAtTick <= tick and instance.lastRunTick ~= tick then
        self:_runToYield(instance, tick, input)
      end
    end
  end
end

-- Resolve at most one new foreground interaction trigger when no foreground
-- root owns the field . A newly created interaction
-- may execute during this tick, matching the source field-control ordering.
function Scheduler:_resolveInteraction(tick, input)
  if self._foregroundEnvironmentId ~= nil then
    return
  end
  local foreground = self._services.foreground
  if foreground == nil or foreground.resolve == nil then
    return
  end
  local hit = foreground.resolve(input)
  if hit == nil then
    return
  end
  local composed = hit.composed
  if composed == nil then
    return
  end
  self:createForeground(composed, hit.trigger, tick)
  local env = assert(self._environments[self._foregroundEnvironmentId])
  self:_runEnvironmentSlots(env, tick, input)
end

-- --- Run-to-yield -------------------------------------------------------------

-- Run one ready context to an explicit yield, block, stop, or fault (spec
-- sections 2 and 26.5). The context is granted at most one run per tick; the
-- node budget counts every continue outcome and faults pathological
-- non-yielding execution instead of yielding implicitly.
function Scheduler:_runToYield(instance, tick, input)
  assert(instance.lastRunTick ~= tick, "context may run at most once per tick")
  instance.status = "running"
  instance.lastRunTick = tick
  instance.yieldReason = nil
  local environment = assert(self._environments[instance.environmentId], "instance environment missing")
  local run = self:_ctxFor(instance, environment, tick, input)
  local frame = instance:topFrame()
  self:_trace("context_run", {
    instanceId = instance.instanceId,
    slot = instance.contextSlot,
    nodeId = frame and frame.nodeId,
  })
  local budget = self._maxNodes
  while true do
    local top = instance:topFrame()
    if top == nil then
      self:_completeInstance(instance, tick)
      return
    end
    local node = top.graph.nodes[top.nodeId]
    local outcome
    if node == nil then
      outcome = Runtime.fallOffEnd(run)
    else
      -- The linear pc advances before execution; branch handlers overwrite
      -- it with their explicit edge.
      top.nodeId = node.next
      local ok, err = pcall(Runtime.executeNode, node, run)
      if not ok then
        if Errors.is(err) then
          local fault = err --[[@as Errors.Error]]
          self:_faultInstance(instance, tick, fault)
          return
        end
        error(err, 0)
      end
      outcome = err
    end
    if outcome == Runtime.OUTCOME_CONTINUE then
      budget = budget - 1
      if budget < 0 then
        self:_faultInstance(
          instance,
          tick,
          Errors.new(
            ScriptErrors.SCRIPT_STEP_BUDGET_EXCEEDED,
            "run-phase node budget exceeded",
            { scriptId = instance.scriptId, instanceId = instance.instanceId, limit = self._maxNodes }
          )
        )
        return
      end
    elseif outcome == Runtime.OUTCOME_YIELD_TICK then
      instance.status = "ready"
      instance.readyAtTick = tick + 1
      instance.yieldReason = "explicit_yield"
      self:_trace("context_yielded", {
        instanceId = instance.instanceId,
        readyAtTick = tick + 1,
      })
      return
    elseif outcome == Runtime.OUTCOME_BLOCK then
      instance.status = "blocked"
      instance.waitingTaskId = run.blockTaskId
      instance.pendingResultRef = run.blockResultRef
      instance.yieldReason = "task"
      self:_trace("context_blocked", {
        instanceId = instance.instanceId,
        taskId = run.blockTaskId,
      })
      return
    elseif outcome == Runtime.OUTCOME_STOP then
      self:_completeInstance(instance, tick)
      return
    end
  end
end

-- --- Completion, faults, and cancellation -------------------------------------

-- Release every lock the instance owns  and cancel its
-- engine-owned movement tasks.
function Scheduler:_releaseInstanceOwnership(instance)
  local environment = self._environments[instance.environmentId]
  if environment then
    environment:releaseLocksFor(instance.instanceId)
    for _, task in ipairs(self._tasks) do
      if task.ownerInstanceId == instance.instanceId and task.taskType == "movement" and task.status == "active" then
        environment:unregisterMovementTask(task.taskId)
        self:_cancelTaskState(task, "owner ended")
      end
    end
  end
end

-- Normal instance completion : release ownership,
-- clear text arguments, free the context slot, and tear down the environment
-- when the root completes.
function Scheduler:_completeInstance(instance, tick)
  instance.status = "completed"
  instance.endReason = "completed"
  instance:clearInstanceState()
  self:_releaseInstanceOwnership(instance)
  self:_emit("script.ended", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    completed = true,
    reason = "completed",
  })
  self:_trace("context_completed", { instanceId = instance.instanceId })
  self:_finishInstanceInEnvironment(instance, "completed")
end

-- Fault one context through attributed cleanup : record the error, release ownership, emit events, and tear
-- down the environment when the faulting context is the root.
---@param instance ScriptInstance
---@param tick integer
---@param error Errors.Error
function Scheduler:_faultInstance(instance, tick, error)
  instance.status = "faulted"
  instance.endReason = error.code
  instance:clearInstanceState()
  self:_emit("script.error", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    code = error.code,
    message = error.message,
    context = error.context,
  })
  self:_releaseInstanceOwnership(instance)
  self:_emit("script.ended", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    completed = false,
    reason = error.code,
  })
  self:_trace("context_faulted", {
    instanceId = instance.instanceId,
    code = error.code,
  })
  self:_finishInstanceInEnvironment(instance, error.code)
end

-- Free the context slot of a finished child, or tear down the whole
-- environment when the finishing instance is the root.
function Scheduler:_finishInstanceInEnvironment(instance, reason)
  local environment = self._environments[instance.environmentId]
  if environment == nil then
    return
  end
  if instance.contextSlot > 0 then
    environment:clearContext(instance.contextSlot)
  else
    self:_teardownEnvironment(environment, reason)
  end
end

-- Cancel a task's implementation state and mark the record cancelled.
function Scheduler:_cancelTaskState(task, reason)
  if task.status == "cancelled" then
    return
  end
  task:cancel(reason)
end

-- Tear down an environment : cancel its remaining active
-- or completed-but-unconsumed tasks, cancel every context, release movement
-- ownership and barrier generations, release locks, clear slots and caller
-- signals, and drop the environment from the scheduler.
---@param environment ScriptEnvironment
---@param reason string
function Scheduler:_teardownEnvironment(environment, reason)
  for _, task in ipairs(self._tasks) do
    if task.environmentId == environment.environmentId and (task.status == "active" or task.status == "completed") then
      self:_cancelTaskState(task, reason)
    end
  end
  for slot = 0, ScriptEnvironment.SLOT_COUNT - 1 do
    local instanceId = environment:contextAt(slot)
    if instanceId ~= nil then
      local instance = self._instances[instanceId]
      if instance and instance.status ~= "completed" and instance.status ~= "faulted" then
        self:_cancelInstance(instance, reason)
      end
    end
  end
  for _, generation in pairs(environment.movementTasksByGeneration) do
    for taskId in pairs(generation) do
      local task = self._tasksById[taskId]
      if task and task.status == "active" then
        self:_cancelTaskState(task, reason)
      end
    end
  end
  environment.locks = {}
  environment.callerSignals = {}
  self._environments[environment.environmentId] = nil
  if environment.mode == "foreground" then
    self._foregroundEnvironmentId = nil
  else
    for i = #self._backgrounds, 1, -1 do
      if self._backgrounds[i] == environment then
        table.remove(self._backgrounds, i)
        break
      end
    end
  end
  self:_trace("environment_torn_down", { environmentId = environment.environmentId })
end

-- Cancel one instance : cancel its tasks, release its
-- ownership, and emit `script.ended` with `completed = false`.
---@param instance ScriptInstance
---@param reason string
function Scheduler:_cancelInstance(instance, reason)
  if instance.status == "completed" or instance.status == "cancelled" then
    return
  end
  for _, task in ipairs(self._tasks) do
    if task.ownerInstanceId == instance.instanceId and (task.status == "active" or task.status == "completed") then
      self:_cancelTaskState(task, reason)
    end
  end
  instance.status = "cancelled"
  instance.endReason = reason
  instance:clearInstanceState()
  self:_releaseInstanceOwnership(instance)
  self:_emit("script.ended", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    completed = false,
    reason = reason,
  })
  self:_trace("context_cancelled", { instanceId = instance.instanceId })
end

-- Cancel a whole environment and everything it owns.
---@param environmentId string
---@param reason string
function Scheduler:cancelEnvironment(environmentId, reason)
  local environment = self._environments[environmentId]
  if environment == nil then
    return
  end
  self:_teardownEnvironment(environment, reason)
end

-- Cancel one instance and, when it is a root, its environment.
---@param instanceId string
---@param reason string
function Scheduler:cancelInstance(instanceId, reason)
  local instance = self._instances[instanceId]
  if instance == nil then
    return
  end
  self:_cancelInstance(instance, reason)
  if instance.contextSlot == 0 then
    local environment = self._environments[instance.environmentId]
    if environment then
      self:_teardownEnvironment(environment, reason)
    end
  end
end

-- Override the run-phase node budget (tests and diagnostics only; the
-- production default is Scheduler.MAX_NONBLOCKING_NODES_PER_TICK).
---@param maxNodes integer
function Scheduler:setMaxNodes(maxNodes)
  assert(type(maxNodes) == "number" and maxNodes > 0, "node budget must be positive")
  self._maxNodes = maxNodes
end

-- Start a foreground interaction outside the scheduler's own tick
-- resolution (used by the session's interaction client, ):
-- creates the environment and runs its slots so the new context may execute
-- during its trigger tick. Returns nil when a foreground root already owns
-- the field.
---@param trigger table
---@param composed table
---@param tick integer
---@return string|nil instanceId
function Scheduler:startInteraction(trigger, composed, tick)
  if self._foregroundEnvironmentId ~= nil then
    return nil
  end
  local instanceId = self:createForeground(composed, trigger, tick)
  local environment = assert(self._environments[self._foregroundEnvironmentId])
  self:_runEnvironmentSlots(environment, tick, self._currentInput)
  return instanceId
end

-- True when player-controlled movement is suppressed: a foreground root owns
-- the field, or the foreground environment holds a player lock.
---@return boolean
function Scheduler:playerMovementLocked()
  if self._foregroundEnvironmentId == nil then
    return false
  end
  local environment = self._environments[self._foregroundEnvironmentId]
  return environment ~= nil and environment:playerLocked()
end

-- --- Accessors -----------------------------------------------------------------

---@return ScriptInstance[]
function Scheduler:instances()
  local out = {}
  for instanceId, instance in pairs(self._instances) do
    out[#out + 1] = instance
  end
  table.sort(out, function(a, b)
    return a.instanceId < b.instanceId
  end)
  return out
end

---@return ScriptTask[]
function Scheduler:tasks()
  local out = {}
  for _, task in ipairs(self._tasks) do
    if task.status ~= "cancelled" and not task.consumed then
      out[#out + 1] = task
    end
  end
  return out
end

---@return ScriptEnvironment[]
function Scheduler:environments()
  return self:_orderedEnvironments()
end

function Scheduler:_orderedEnvironments()
  local out = {}
  if self._foregroundEnvironmentId ~= nil then
    out[#out + 1] = self._environments[self._foregroundEnvironmentId]
  end
  for _, env in ipairs(self._backgrounds) do
    out[#out + 1] = env
  end
  return out
end

---@param instanceId string
---@return ScriptInstance|nil
function Scheduler:instance(instanceId)
  return self._instances[instanceId]
end

---@param taskId string
---@return ScriptTask|nil
function Scheduler:tasksById(taskId)
  return self._tasksById[taskId]
end

-- The active movement task for one actor in one environment, or nil
-- (two foreground tasks cannot own the same actor).
---@param environmentId string
---@param actorId string
---@return string|nil
function Scheduler:activeMovementForActor(environmentId, actorId)
  for _, task in ipairs(self._tasks) do
    if
      task.status == "active"
      and task.environmentId == environmentId
      and task.taskType == "movement"
      and task.state ~= nil
      and task.state.actor == actorId
    then
      return task.taskId
    end
  end
  return nil
end

---@return string|nil
function Scheduler:foregroundEnvironmentId()
  return self._foregroundEnvironmentId
end

-- The immutable input snapshot of the current step (the game's dialogue host
-- consumes it from the engine-owned async phase).
---@return table|nil
function Scheduler:currentInput()
  return self._currentInput
end

-- --- Save hooks -----------------------------------------------------------------

---@return string
function Scheduler:taskRegistryFingerprint()
  return self._taskRegistry:fingerprint()
end

---@param taskType string
---@param version integer
---@return TaskImplementation|nil, Errors.Error|nil
function Scheduler:resolveTask(taskType, version)
  return self._taskRegistry:resolve(taskType, version)
end

function Scheduler:counters()
  return {
    nextEnvironmentId = self._nextEnvironmentId,
    nextInstanceId = self._nextInstanceId,
    nextTaskId = self._nextTaskId,
  }
end

-- Rebuild the scheduler's script state from a ScriptSave scripts bucket
-- . The restore tick is the load boundary: the caller
-- resumes with the first step at restoreTick + 1, so relative delays rebase
-- exactly and no tick is duplicated or skipped. The caller is responsible
-- for the registry and task-registry fingerprint checks (ScriptSave.restore
-- performs them); this method reattaches environments, instances, tasks, and
-- composition chains, verifying every frame's graph revision against the
-- current compositions .
---@param bucket table
---@param restoreTick integer
function Scheduler:restoreScriptState(bucket, restoreTick)
  assert(self._foregroundEnvironmentId == nil and next(self._instances) == nil, "restore requires an idle scheduler")
  local graphs = {}

  -- Collect every referenced graph revision through the frame chain
  -- identities; a revision that no current composition produces is a save
  -- mismatch (SCRIPT_SAVE_REVISION_MISMATCH).
  for _, instanceRecord in ipairs(bucket.instances or {}) do
    for _, frameRecord in ipairs(instanceRecord.frames or {}) do
      local composed = self:resolveComposition(frameRecord.chainScriptId)
      if composed == nil or composed.revision ~= frameRecord.chainRevision then
        Errors.raise(
          ScriptErrors.SCRIPT_SAVE_REVISION_MISMATCH,
          "save references an unknown composed script revision",
          {
            scriptId = frameRecord.chainScriptId,
            revision = frameRecord.chainRevision,
            composedRevision = composed and composed.revision or nil,
          }
        )
      end
      composed = composed --[[@as table]]
      local entryIndex = frameRecord
        .composition --[[@as table]]
        .entryIndex + 1
      local entry = composed.entries[entryIndex]
      if entry == nil then
        Errors.raise(
          ScriptErrors.SCRIPT_SAVE_REVISION_MISMATCH,
          "save references an unknown composition entry",
          { scriptId = frameRecord.chainScriptId, entryIndex = entryIndex }
        )
      end
      entry = entry --[[@as table]]
      if entry.graph.revision ~= frameRecord.graphRevision then
        Errors.raise(
          ScriptErrors.SCRIPT_SAVE_REVISION_MISMATCH,
          "save references an unknown graph revision",
          { scriptId = frameRecord.chainScriptId, revision = frameRecord.graphRevision }
        )
      end
      graphs[frameRecord.graphRevision] = entry.graph
    end
  end

  local environments = {}
  for _, envRecord in ipairs(bucket.environments or {}) do
    local environment = ScriptEnvironment.restore(envRecord, restoreTick)
    self._environments[environment.environmentId] = environment
    environments[#environments + 1] = environment
    if environment.mode == "foreground" then
      self._foregroundEnvironmentId = environment.environmentId
    else
      self._backgrounds[#self._backgrounds + 1] = environment
    end
  end

  local instances = {}
  for _, instanceRecord in ipairs(bucket.instances or {}) do
    local instance = ScriptInstance.restore(instanceRecord, restoreTick, graphs)
    for _, frame in ipairs(instance.frames) do
      local composed = self:resolveComposition(frame.chainScriptId)
      assert(composed and composed.revision == frame.chainRevision, "frame chain must resolve after the revision check")
      frame.chain = composed.entries
      frame.graph = graphs[frame.graphRevision]
    end
    self._instances[instance.instanceId] = instance
    instances[#instances + 1] = instance
  end

  for _, taskRecord in ipairs(bucket.tasks or {}) do
    local task = ScriptTask.restore(taskRecord, restoreTick)
    self._tasks[#self._tasks + 1] = task
    self._tasksById[task.taskId] = task
  end

  self._nextEnvironmentId = bucket.nextEnvironmentId or 0
  self._nextInstanceId = bucket.nextInstanceId or 0
  self._nextTaskId = bucket.nextTaskId or 0
end

return Scheduler
