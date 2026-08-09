-- Versioned script task registry : every task type is
-- registered by a stable name and major version; implementations supply
-- `create`, `poll`, and `validate`. The scheduler routes task
-- creation and polling through this registry so save records can verify both
-- the type and the version on load (section 28.7), and so raw-Lua handlers can
-- only ever return a task type that is registered here (section 21.2). The
-- deterministic fingerprint covers every registered type and version; saves
-- store it and reject a mismatch. Pure domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local LuaWriter = require("libs.rom.src.LuaWriter")
local Sha256 = require("libs.engine.src.script.Sha256")

---@class TaskImplementation
---@field type string
---@field version integer
---@field create fun(spec: table, ctx: table): any
---@field poll fun(state: any, ctx: table): table
---@field validate fun(state: any): Errors.Error|nil
---@field onComplete fun(state: any, ctx: table)|nil

---@class TaskRegistry
---@field private _byType table<string, table<integer, TaskImplementation>>
---@field private _order string[]
local TaskRegistry = {}
TaskRegistry.__index = TaskRegistry

---@return TaskRegistry
function TaskRegistry.new()
  return setmetatable({
    _byType = {},
    _order = {},
  }, TaskRegistry)
end

-- Register a task implementation under a stable type name and major version.
-- Registering the same type and version twice is a programming invariant.
---@param taskType string
---@param version integer
---@param impl TaskImplementation
function TaskRegistry:register(taskType, version, impl)
  assert(type(taskType) == "string" and taskType ~= "", "task type required")
  assert(type(version) == "number", "task version required")
  assert(type(impl) == "table" and type(impl.poll) == "function", "task implementation must supply poll")
  assert(type(impl.create) == "function", "task implementation must supply create")
  local versions = self._byType[taskType]
  if versions == nil then
    versions = {}
    self._byType[taskType] = versions
    self._order[#self._order + 1] = taskType
  end
  assert(versions[version] == nil, "task type " .. taskType .. " version " .. version .. " registered twice")
  versions[version] = impl
end

-- Resolve a task implementation; unknown types and versions are attributed
-- save errors (section 28.7), never silently skipped.
---@param taskType string
---@param version integer
---@return TaskImplementation|nil, Errors.Error|nil
function TaskRegistry:resolve(taskType, version)
  local versions = self._byType[taskType]
  if versions == nil then
    return nil,
      Errors.new(
        ScriptErrors.SCRIPT_TASK_UNKNOWN,
        "no registered task type " .. tostring(taskType),
        { taskType = taskType }
      )
  end
  local impl = versions[version]
  if impl == nil then
    return nil,
      Errors.new(
        ScriptErrors.SCRIPT_TASK_VERSION_UNSUPPORTED,
        "task type " .. tostring(taskType) .. " has no version " .. tostring(version),
        { taskType = taskType, version = version }
      )
  end
  return impl
end

-- Deterministic fingerprint over every registered (type, version) pair; the
-- save schema stores it and load rejects a mismatch (section 28.1).
---@return string
function TaskRegistry:fingerprint()
  local projection = {}
  for _, taskType in ipairs(self._order) do
    local versions = {}
    for version in pairs(self._byType[taskType]) do
      versions[#versions + 1] = version
    end
    table.sort(versions)
    projection[#projection + 1] = { type = taskType, versions = versions }
  end
  return Sha256.hex(LuaWriter.encode(projection))
end

return TaskRegistry
