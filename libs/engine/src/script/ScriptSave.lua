-- Script save and resume : the serializable `scripts`
-- bucket of the g4-field-save-v2 schema. Capture happens only at a fixed-tick
-- phase boundary (no context in `running` status); absolute scheduling ticks
-- become relative delays rebased at restore, so no tick is duplicated or
-- skipped. The bucket carries the registry fingerprint, the task-registry
-- fingerprint, and the id counters; restore rejects a fingerprint mismatch
-- (SCRIPT_REGISTRY_FINGERPRINT_MISMATCH) and the scheduler reattaches every
-- frame's graph through current compositions, rejecting unknown revisions
-- (SCRIPT_SAVE_REVISION_MISMATCH). Input edges are never serialized. Pure
-- domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local ScriptTask = require("libs.engine.src.script.ScriptTask")

local ScriptSave = {}

ScriptSave.SCHEMA_NAME = "g4-script-save-v1"

---@param scheduler Scheduler
---@param tick integer
---@param opts table
---@return table bucket
function ScriptSave.capture(scheduler, tick, opts)
  assert(opts and type(opts.registryFingerprint) == "string", "registry fingerprint required for capture")
  for _, instance in ipairs(scheduler:liveInstances()) do
    assert(instance.status ~= "running", "capture requires a fixed-tick phase boundary (no running context)")
  end
  local environments = {}
  for _, environment in ipairs(scheduler:environments()) do
    environments[#environments + 1] = environment:capture()
  end
  local instances = {}
  for _, instance in ipairs(scheduler:liveInstances()) do
    instances[#instances + 1] = instance:capture(tick)
  end
  local tasks = {}
  for _, task in ipairs(scheduler:tasks()) do
    tasks[#tasks + 1] = task:capture(tick)
  end
  local counters = scheduler:counters()
  return {
    schema = ScriptSave.SCHEMA_NAME,
    registryFingerprint = opts.registryFingerprint,
    taskFingerprint = scheduler:taskRegistryFingerprint(),
    capturedAtSimulationTick = tick,
    nextEnvironmentId = counters.nextEnvironmentId,
    nextInstanceId = counters.nextInstanceId,
    nextTaskId = counters.nextTaskId,
    environments = environments,
    instances = instances,
    tasks = tasks,
  }
end

-- Validate the bucket envelope. Returns nil when valid, else an Errors
-- object; raising variants of the checks are used by restore.
---@param bucket any
---@param opts table
---@return Errors.Error|nil
function ScriptSave.validate(bucket, opts)
  if type(bucket) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "scripts bucket must be a table", {})
  end
  if bucket.schema ~= ScriptSave.SCHEMA_NAME then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "unknown scripts bucket schema " .. tostring(bucket.schema),
      { schema = bucket.schema }
    )
  end
  if opts.expectedRegistryFingerprint ~= nil and bucket.registryFingerprint ~= opts.expectedRegistryFingerprint then
    return Errors.new(
      ScriptErrors.SCRIPT_REGISTRY_FINGERPRINT_MISMATCH,
      "scripts bucket registry fingerprint does not match the loaded registry",
      { expected = opts.expectedRegistryFingerprint, actual = bucket.registryFingerprint }
    )
  end
  if opts.expectedTaskFingerprint ~= nil and bucket.taskFingerprint ~= opts.expectedTaskFingerprint then
    return Errors.new(
      ScriptErrors.SCRIPT_REGISTRY_FINGERPRINT_MISMATCH,
      "scripts bucket task fingerprint does not match the loaded task registry",
      { expected = opts.expectedTaskFingerprint, actual = bucket.taskFingerprint }
    )
  end
  return nil
end

-- Restore a scripts bucket into an idle scheduler. `restoreTick` is the load
-- boundary: the caller resumes with the first step at restoreTick + 1, so
-- relative delays rebase exactly. Raises on fingerprint
-- mismatch, unknown task types or versions, invalid task state, or unknown
-- graph revisions.
---@param bucket table
---@param scheduler Scheduler
---@param restoreTick integer
---@param opts table
function ScriptSave.restore(bucket, scheduler, restoreTick, opts)
  opts = opts or {}
  local envelopeErr = ScriptSave.validate(bucket, {
    expectedRegistryFingerprint = opts.expectedRegistryFingerprint,
    expectedTaskFingerprint = scheduler:taskRegistryFingerprint(),
  })
  if envelopeErr ~= nil then
    Errors.raise(envelopeErr.code, envelopeErr.message, envelopeErr.context)
  end

  -- Task types and versions must resolve, and the task implementation must
  -- accept the serialized state.
  for _, taskRecord in ipairs(bucket.tasks or {}) do
    local recordErr = ScriptTask.validateRecord(taskRecord)
    if recordErr ~= nil then
      Errors.raise(recordErr.code, recordErr.message, recordErr.context)
    end
    local impl, resolveErr = scheduler:resolveTask(taskRecord.taskType, taskRecord.taskVersion)
    if not impl then
      local err = resolveErr --[[@as Errors.Error]]
      Errors.raise(err.code, err.message, err.context)
    end
    impl = impl --[[@as table]]
    local stateErr = impl.validate(taskRecord.state)
    if stateErr ~= nil then
      Errors.raise(stateErr.code, stateErr.message, stateErr.context)
    end
  end

  scheduler:restoreScriptState(bucket, restoreTick)
end

return ScriptSave
