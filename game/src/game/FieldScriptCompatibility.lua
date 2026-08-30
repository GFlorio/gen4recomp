-- Owns the production field-script registry, task registry, and composition
-- construction shared by field execution and persisted-save validation.

local Composition = require("libs.engine.src.script.Composition")
local Errors = require("libs.errors.src.Errors")
local RegistrySnapshot = require("libs.engine.src.script.RegistrySnapshot")
local RegistryWarmup = require("libs.engine.src.script.RegistryWarmup")
local ScriptLoader = require("libs.engine.src.script.ScriptLoader")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")

---@class FieldScriptCompatibility.MovementPause: TaskImplementation
---@field actorType string
---@class FieldScriptCompatibility
---@field registry Registry current production script registry
---@field registrySnapshotKey string|nil key the registry was built under
---@field registrySnapshotUsed boolean whether a matching snapshot supplied its fingerprint
---@field warmup RegistryWarmup|nil background registry warm-up after a snapshot miss
---@field composition Composition current production script composition
---@field taskRegistry TaskRegistry current production task registry
---@field registryFingerprint fun(self: FieldScriptCompatibility): string
local TASK_MODULES = {
  "libs.engine.src.script.tasks.WaitTicksTask",
  "libs.engine.src.script.tasks.WaitInputTask",
  "libs.engine.src.script.tasks.WaitInputOrTicksTask",
  "libs.engine.src.script.tasks.WaitSignpostActionTask",
  "libs.engine.src.script.tasks.TrainerTipsTask",
  "libs.engine.src.script.tasks.WaitSignpostTask",
  "libs.engine.src.script.tasks.SignTask",
  "libs.engine.src.script.tasks.DialogueTask",
  "libs.engine.src.script.tasks.MovementTask",
  "libs.engine.src.script.tasks.MovementBarrierTask",
  "libs.engine.src.script.tasks.MovementPauseTask",
  "libs.engine.src.script.tasks.FadeTask",
  "libs.engine.src.script.tasks.SoundWaitTask",
  "libs.engine.src.script.tasks.MusicFadeTask",
  "libs.engine.src.script.tasks.WarpTask",
  "libs.engine.src.script.tasks.ChildScriptTask",
  "libs.engine.src.script.tasks.AskYesNoTask",
  "libs.engine.src.script.tasks.AuxiliaryUiTask",
  "libs.engine.src.script.tasks.ContextChoiceTask",
  "libs.engine.src.script.tasks.MenuTask",
}

local FieldScriptCompatibility = {}
FieldScriptCompatibility.__index = FieldScriptCompatibility

local function buildTaskRegistry()
  local registry = TaskRegistry.new()
  for _, moduleName in ipairs(TASK_MODULES) do
    local impl = require(moduleName)
    ---@cast impl TaskImplementation
    registry:register(impl.type, impl.version, impl)
  end
  local pause = require("libs.engine.src.script.tasks.MovementPauseTask")
  ---@cast pause FieldScriptCompatibility.MovementPause
  registry:register(pause.actorType, pause.version, pause)
  return registry
end

---@param opts { cacheFs: CacheFs, overrideFs: table }
---@return FieldScriptCompatibility
function FieldScriptCompatibility.new(opts)
  assert(opts and opts.cacheFs and opts.overrideFs, "script compatibility requires filesystems")
  local snapshot = RegistrySnapshot.load(opts.cacheFs, opts.overrideFs)
  local fast = snapshot ~= nil and snapshot.fingerprint ~= nil
  local registry = ScriptLoader.buildRegistry(opts.cacheFs, opts.overrideFs, nil, {
    lazy = true,
    validateGenerated = not fast,
  })
  if snapshot ~= nil and snapshot.fingerprint ~= nil then
    registry:restoreFingerprint(snapshot.fingerprint)
  end
  local self = setmetatable({
    registry = registry,
    registrySnapshotKey = snapshot and snapshot.key or nil,
    registrySnapshotUsed = fast,
    warmup = nil,
    composition = Composition.new(registry),
    taskRegistry = buildTaskRegistry(),
  }, FieldScriptCompatibility) --[[@as FieldScriptCompatibility]]
  if not fast then
    self.warmup = RegistryWarmup.new({
      registry = registry,
      cacheFs = opts.cacheFs,
      overrideFs = opts.overrideFs,
      snapshotKey = snapshot and snapshot.key or nil,
    })
  end
  return self
end

---@return string
function FieldScriptCompatibility:registryFingerprint()
  if self.warmup ~= nil then
    local failure = self.warmup:finish()
    if failure ~= nil then
      Errors.raise(failure.code, failure.message, failure.context)
    end
  end
  return self.registry:fingerprint()
end

---@return table
function FieldScriptCompatibility:validationOptions()
  local function resolveTask(taskType, version)
    return self.taskRegistry:resolve(taskType, version)
  end
  local function resolveComposition(scriptId)
    return self.composition:effective(scriptId)
  end
  return {
    expectedRegistryFingerprint = self:registryFingerprint(),
    expectedTaskFingerprint = self.taskRegistry:fingerprint(),
    resolveTask = resolveTask,
    resolveComposition = resolveComposition,
  }
end

return FieldScriptCompatibility
