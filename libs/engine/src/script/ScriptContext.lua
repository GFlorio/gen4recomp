-- Public ScriptContext v1: the stable service facade a named raw-Lua handler
-- receives. It never exposes the app object, the renderer, global LÖVE state,
-- physical save tables, or mutable engine subsystem tables; every service is a
-- thin read-only or validated facade over the injected services. `ctx.tasks`
-- is the only way to start blocking work: every factory returns a serializable
-- task descriptor `{taskType, taskVersion, state}` that the scheduler turns
-- into a real task record with scheduler-owned lifecycle fields. `ctx.events`
-- restricts mods to their own namespace. ScriptObject snapshots are invalid
-- after the handler returns. Pure domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local Serializable = require("libs.engine.src.script.Serializable")

local ScriptContext = {}

ScriptContext.API_VERSION = 1

-- --- ScriptObject snapshot facade ----------------------------------------------

---@class ScriptObject
---@field private _snapshot table
---@field private _valid boolean
local ScriptObject = {}
ScriptObject.__index = ScriptObject

local function requireValid(object)
  if not object._valid then
    Errors.raise(
      ScriptErrors.SCRIPT_RAW_RESULT_INVALID,
      "a ScriptObject snapshot is invalid after the raw handler returns",
      { objectId = object._snapshot.actorId }
    )
  end
end

function ScriptObject:id()
  requireValid(self)
  return self._snapshot.actorId
end
function ScriptObject:mapId()
  requireValid(self)
  return self._snapshot.mapId
end
function ScriptObject:position()
  requireValid(self)
  return self._snapshot.position
end
function ScriptObject:facing()
  requireValid(self)
  return self._snapshot.facing
end
function ScriptObject:visible()
  requireValid(self)
  return self._snapshot.visible
end
function ScriptObject:movementType()
  requireValid(self)
  return self._snapshot.movementType
end

local function invalidateObjects(ctx)
  for _, object in ipairs(ctx._objects) do
    object._valid = false
  end
end

-- --- Task descriptors ----------------------------------------------------------

-- Build a task descriptor from a spec; every factory validates its spec
-- here so raw handlers cannot smuggle malformed task state.
---@param taskType string
---@param taskVersion integer
---@param spec table
---@return table descriptor
local function taskDescriptor(taskType, taskVersion, spec)
  assert(type(spec) == "table", "task spec must be a table")
  if not Serializable.is(spec) then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "task state must be serializable", { taskType = taskType })
  end
  return { taskType = taskType, taskVersion = taskVersion, state = spec }
end

-- --- The context ---------------------------------------------------------------

-- Build the v1 context for one raw handler invocation.
---@param opts table { scheduler, instance, environment, services, owner }
---@return table ctx
function ScriptContext.build(opts)
  local scheduler = opts.scheduler
  local instance = opts.instance
  local environment = opts.environment
  local services = opts.services
  local owner = opts.owner
  local trigger = instance.trigger

  local ctx = {
    apiVersion = ScriptContext.API_VERSION,
    _objects = {},
  }

  ctx.script = {
    id = function()
      return instance.scriptId
    end,
    instanceId = function()
      return instance.instanceId
    end,
    owner = function()
      return instance.owner
    end,
    trigger = function()
      return trigger
    end,
    call = function(_, scriptId, args)
      assert(type(scriptId) == "string", "call target must be a script id")
      return taskDescriptor("child_script", 1, { scriptId = scriptId, args = args or {} })
    end,
  }

  ctx.flags = {
    get = function(_, id)
      return services.world:isFlagSet(id)
    end,
    set = function(_, id)
      services.world:setFlag(id)
    end,
    clear = function(_, id)
      services.world:clearFlag(id)
    end,
  }

  ctx.variables = {
    get = function(_, id)
      return services.world:getVar(id)
    end,
    set = function(_, id, value)
      services.world:setVar(id, value)
    end,
    add = function(_, id, amount)
      services.world:addVar(id, amount)
    end,
    sub = function(_, id, amount)
      services.world:subVar(id, amount)
    end,
  }

  ctx.locals = {
    get = function(_, name)
      return instance.locals[name]
    end,
    set = function(_, name, value)
      if not Serializable.is(value) then
        Errors.raise(
          ScriptErrors.SCRIPT_RAW_RESULT_INVALID,
          "local values must remain serializable",
          { localName = name }
        )
      end
      instance.locals[name] = value
    end,
  }

  local function objectFor(ref)
    local actorId = type(ref) == "string" and ref or (ref and ref.id) or nil
    if actorId == nil or not services.actors:exists(actorId) then
      return nil
    end
    return actorId
  end

  ctx.objects = {
    get = function(_, ref)
      local actorId = objectFor(ref)
      if actorId == nil then
        return nil
      end
      local snapshot = services.actors:snapshot(actorId)
      if snapshot == nil then
        return nil
      end
      local object = setmetatable({ _snapshot = snapshot, _valid = true }, ScriptObject)
      ctx._objects[#ctx._objects + 1] = object
      return object
    end,
    require = function(_, ref)
      local object = ctx.objects.get(ctx.objects, ref)
      if object == nil then
        Errors.raise(
          ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
          "no live actor for the object reference",
          { scriptId = instance.scriptId, actor = tostring(ref) }
        )
      end
      return object
    end,
    exists = function(_, ref)
      return objectFor(ref) ~= nil
    end,
    show = function(_, ref)
      local actorId = objectFor(ref)
      if actorId ~= nil then
        services.actors:show(actorId)
      end
    end,
    hide = function(_, ref)
      local actorId = objectFor(ref)
      if actorId ~= nil then
        services.actors:hide(actorId)
      end
    end,
    setPosition = function(_, ref, position)
      local actorId = objectFor(ref)
      if actorId ~= nil then
        services.actors:setPosition(actorId, position)
      end
    end,
    setFacing = function(_, ref, direction)
      local actorId = objectFor(ref)
      if actorId ~= nil then
        services.actors:setFacing(actorId, direction)
      end
    end,
  }

  ctx.player = {
    position = function()
      return services.player:position()
    end,
    facing = function()
      return services.player:facing()
    end,
    gender = function()
      return services.player:gender()
    end,
    name = function()
      return services.player:name()
    end,
    isLocked = function()
      return environment:playerLocked()
    end,
  }

  ctx.dialogue = {
    isOpen = function()
      if services.dialogue == nil or services.dialogue.isOpen == nil then
        return false
      end
      return services.dialogue:isOpen()
    end,
    resolve = function(_, messageRef, bindings)
      if services.dialogue == nil or services.dialogue.resolveText == nil then
        Errors.raise(
          ScriptErrors.SCRIPT_RAW_HANDLER_ERROR,
          "dialogue resolution is unavailable",
          { scriptId = instance.scriptId }
        )
      end
      return {
        message = messageRef,
        bindings = bindings,
        rendered = services.dialogue:resolveText(messageRef),
      }
    end,
  }

  ctx.movement = {
    isActorBusy = function(_, ref)
      local actorId = objectFor(ref)
      return actorId ~= nil and services.actors:isBusy(actorId)
    end,
    canMove = function(_, ref, direction)
      local actorId = objectFor(ref)
      return actorId ~= nil and services.actors:canMove(actorId, direction)
    end,
  }

  -- Camera and maps raise an attributed error when the owning subsystem has
  -- not been wired; the other facades degrade gracefully.
  local function requireService(name)
    local service = services[name]
    if service == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_RAW_HANDLER_ERROR,
        name .. " service is unavailable",
        { scriptId = instance.scriptId }
      )
    end
    return service
  end

  ctx.camera = {
    target = function()
      return requireService("camera"):target()
    end,
    mode = function()
      return requireService("camera"):mode()
    end,
  }

  ctx.maps = {
    currentId = function()
      return requireService("maps"):currentId()
    end,
    resolve = function(_, ref)
      return requireService("maps"):resolve(ref)
    end,
    has = function(_, ref)
      return requireService("maps"):has(ref)
    end,
  }

  ctx.audio = {
    isPlaying = function(_, soundId)
      if services.audio == nil or services.audio.isPlaying == nil then
        return false
      end
      return services.audio:isPlaying(soundId)
    end,
  }

  ctx.events = {
    emit = function(_, name, payload)
      local modId = owner and owner.id or ""
      local prefix = "mod." .. modId .. "."
      if type(name) ~= "string" or name:sub(1, #prefix) ~= prefix then
        Errors.raise(
          ScriptErrors.SCRIPT_RAW_RESULT_INVALID,
          "mods may emit only mod.<own_mod_id>.* events",
          { scriptId = instance.scriptId, modId = modId, event = name }
        )
      end
      if services.events and services.events.emit then
        services.events:emit(name, payload)
      end
    end,
  }

  ctx.tasks = {
    waitTicks = function(_, spec)
      return taskDescriptor("wait_ticks", 1, spec)
    end,
    waitInput = function(_, spec)
      return taskDescriptor("wait_input", 1, spec)
    end,
    dialogue = function(_, spec)
      return taskDescriptor("dialogue", 1, spec)
    end,
    movement = function(_, spec)
      return taskDescriptor("movement", 1, spec)
    end,
    movementBarrier = function(_, spec)
      return taskDescriptor("movement_barrier", 1, spec)
    end,
    fade = function(_, spec)
      return taskDescriptor("fade", 1, spec)
    end,
    soundWait = function(_, spec)
      return taskDescriptor("sound_wait", 1, spec)
    end,
    warp = function(_, spec)
      return taskDescriptor("warp", 1, spec)
    end,
    starterChoice = function(_, spec)
      return taskDescriptor("starter_choice", 1, spec)
    end,
  }

  ctx.random = {
    nextInt = function(_, maxExclusive)
      return services.world.rng:nextInt(maxExclusive)
    end,
    range = function(_, minInclusive, maxInclusive)
      return services.world.rng:range(minInclusive, maxInclusive)
    end,
    chance = function(_, numerator, denominator)
      return services.world.rng:chance(numerator, denominator)
    end,
  }

  ctx.log = {
    debug = function(_, message, fields)
      if services.log and services.log.debug then
        services.log:debug(message, fields)
      end
    end,
    info = function(_, message, fields)
      if services.log and services.log.info then
        services.log:info(message, fields)
      end
    end,
    warn = function(_, message, fields)
      if services.log and services.log.warn then
        services.log:warn(message, fields)
      end
    end,
  }

  ctx.invalidate = function()
    invalidateObjects(ctx)
  end

  return ctx
end

return ScriptContext
