-- Raw-Lua handler invocation : resolves the module and
-- function through the ownership-aware module registry, builds the v1
-- ScriptContext, invokes the handler through a fresh coroutine, and validates
-- the result. Allowed returns are nil, a serializable scalar or table (only
-- when the blocking node declared a result reference), or a task descriptor
-- created by ctx.tasks; the descriptor becomes one authoritative scheduler
-- task that the lua node blocks on. Functions, threads, userdata, arbitrary
-- tables, and attempted yields are attributed errors. Every failure is
-- attributed to mod, script, node, module, and function. Pure domain module:
-- no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local Serializable = require("libs.engine.src.script.Serializable")
local ScriptContext = require("libs.engine.src.script.ScriptContext")

local RawInvocation = {}

-- True when the value is a task descriptor produced by ctx.tasks: exactly
-- the stable {taskType, taskVersion, state} envelope (the classifier rejects
-- descriptor-shaped tables carrying unrelated extra fields).
---@param value any
---@return boolean
local function isTaskDescriptor(value)
  if
    type(value) ~= "table"
    or type(value.taskType) ~= "string"
    or type(value.taskVersion) ~= "number"
    or type(value.state) ~= "table"
  then
    return false
  end
  local fields = 0
  for key in pairs(value) do
    fields = fields + 1
  end
  return fields == 3
end

-- Validate a handler result against the blocking node's declared result ref.
-- Returns "none" (nil), "value", or "task" for the lua node handler;
-- anything else raises the attributed error.
---@param value any
---@param declaredResult any
---@param context table
---@return string
function RawInvocation.classify(value, declaredResult, context)
  if value == nil then
    return "none"
  end
  local ty = type(value)
  if ty == "function" or ty == "thread" or ty == "userdata" then
    Errors.raise(
      ScriptErrors.SCRIPT_RAW_RESULT_INVALID,
      "raw handler returned a " .. ty .. "; only serializable values or task descriptors",
      context
    )
  end
  if isTaskDescriptor(value) then
    return "task"
  end
  if not Serializable.is(value) then
    Errors.raise(ScriptErrors.SCRIPT_RAW_RESULT_INVALID, "raw handler result must be serializable", context)
  end
  if declaredResult == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_RAW_RESULT_INVALID,
      "raw handler returned a value but the lua node declares no result",
      context
    )
  end
  return "value"
end

-- Invoke one raw handler. Returns the classification plus the value, or
-- raises the attributed error.
---@param opts table { modules, scheduler, instance, environment, services,
--- node, module, fn, args }
---@return string classification, any value
function RawInvocation.invoke(opts)
  local modules = opts.modules
  local module, owner = modules:resolve(opts.module)
  local fn = module[opts.fn]
  if type(fn) ~= "function" then
    Errors.raise(
      ScriptErrors.SCRIPT_RAW_FUNCTION_NOT_FOUND,
      "raw module " .. opts.module .. " has no function " .. opts.fn,
      { module = opts.module, fn = opts.fn, scriptId = opts.instance.scriptId }
    )
  end
  local ctx = ScriptContext.build({
    scheduler = opts.scheduler,
    instance = opts.instance,
    environment = opts.environment,
    services = opts.services,
    owner = owner,
  })
  local context = {
    modId = owner and owner.id or nil,
    scriptId = opts.instance.scriptId,
    nodeId = opts.node and opts.node.nodeId or nil,
    module = opts.module,
    fn = opts.fn,
  }
  -- The handler runs inside a fresh coroutine so an attempted yield is
  -- observable: a normal return leaves the coroutine dead, while a yield
  -- leaves it suspended (the host main loop is itself a coroutine, so a bare
  -- coroutine.yield would otherwise silently suspend the simulation).
  local co = coroutine.create(fn)
  local ok, result = coroutine.resume(co, ctx, opts.args or {})
  ctx.invalidate()
  if not ok then
    -- An attributed error raised inside the handler re-raises unchanged.
    if Errors.is(result) then
      error(result)
    end
    Errors.raise(ScriptErrors.SCRIPT_RAW_HANDLER_ERROR, tostring(result), context)
  end
  if coroutine.status(co) == "suspended" then
    Errors.raise(ScriptErrors.SCRIPT_RAW_HANDLER_YIELDED, "raw handlers must not yield", context)
  end
  local classification = RawInvocation.classify(result, opts.node and opts.node.result, context)
  return classification, result
end

return RawInvocation
