-- Project-owned world state for the script platform: the flag and variable
-- stores plus the serialized script RNG. Symbol catalogs (flag/var name ->
-- numeric id) come from curated manifests; every access resolves symbolic
-- names through the catalog when one exists, so scripts stay symbolic while
-- the underlying stores (and the actor layer that listens to numeric flags)
-- stay numeric. The event store is either injected (the game owns the
-- authoritative FieldEventState for save restore) or
-- constructed from a serialized events table. The world bucket of
-- g4-field-save-v4 captures directly from this module. Pure domain module:
-- no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldEventState = require("libs.engine.src.FieldEventState")
local ScriptRng = require("libs.hgss.src.script.ScriptRng")

---@class WorldState
---@field private _events FieldEventState
---@field private _catalogs table|nil
---@field rng table
local WorldState = {}
WorldState.__index = WorldState

WorldState.SCHEMA_NAME = "g4-world-state-v1"

local WORLD_FIELDS = { flags = true, variables = true, objects = true, rng = true }

---@param record any
---@return table|nil, Errors.Error?
function WorldState.validate(record)
  if type(record) ~= "table" then
    return nil, Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "world bucket must be a table", {})
  end
  for key in pairs(record) do
    if not WORLD_FIELDS[key] then
      return nil,
        Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "world bucket contains an unknown field", { field = key })
    end
  end
  for _, key in ipairs({ "flags", "variables", "objects", "rng" }) do
    if type(record[key]) ~= "table" then
      return nil, Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "world bucket field is required", { field = key })
    end
  end
  local events, eventErr = FieldEventState.validate({ flags = record.flags, vars = record.variables })
  if not events then
    return nil, assert(eventErr)
  end
  for key in pairs(record.objects) do
    return nil,
      Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "world object state is unsupported", { field = key })
  end
  local rng, rngErr = ScriptRng.validate(record.rng)
  if not rng then
    return nil, assert(rngErr)
  end
  return { flags = events.flags, variables = events.vars, objects = {}, rng = rng }
end

-- Resolve a flag/var id through the catalog: symbolic names become numeric
-- ids when the catalog knows them; unknown symbolic names are attributed
-- reference errors so typos fail loudly.
---@param id any
---@param kind string
---@param catalogs table|nil
---@param hint string
---@return any resolved id
local function resolveId(id, kind, catalogs, hint)
  if type(id) ~= "string" then
    return id
  end
  local catalog = catalogs and catalogs[kind]
  if catalog == nil then
    return id
  end
  local resolved = catalog[id]
  if resolved == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "unknown " .. kind .. " symbol " .. id,
      { symbol = id, kind = kind, use = hint }
    )
  end
  return resolved
end

-- `opts.eventState` injects a live FieldEventState (the game's authoritative
-- store); otherwise `opts.events` seeds a fresh one ({flags, vars} maps).
---@param opts table|nil { eventState?, events?, catalogs?, rng?, seed? }
---@return WorldState
function WorldState.new(opts)
  opts = opts or {}
  local events = opts.eventState
  if events == nil then
    events = FieldEventState.new(opts.events)
  end
  assert(
    type(events.isFlagSet) == "function" and type(events.serialize) == "function",
    "world state requires an event state"
  )
  return setmetatable({
    _events = events,
    _catalogs = opts.catalogs,
    rng = opts.rng or ScriptRng.new(opts.seed),
  }, WorldState)
end

function WorldState:isFlagSet(id)
  return self._events:isFlagSet(resolveId(id, "flags", self._catalogs, "flag")) == true
end

function WorldState:setFlag(id)
  self._events:setFlag(resolveId(id, "flags", self._catalogs, "flag"))
end

function WorldState:clearFlag(id)
  self._events:clearFlag(resolveId(id, "flags", self._catalogs, "flag"))
end

function WorldState:getVar(id)
  return self._events:getVar(resolveId(id, "variables", self._catalogs, "variable"))
end

function WorldState:setVar(id, value)
  self._events:setVar(resolveId(id, "variables", self._catalogs, "variable"), value)
end

function WorldState:addVar(id, amount)
  local resolved = resolveId(id, "variables", self._catalogs, "variable")
  self._events:setVar(resolved, self._events:getVar(resolved) + amount)
end

function WorldState:subVar(id, amount)
  local resolved = resolveId(id, "variables", self._catalogs, "variable")
  self._events:setVar(resolved, self._events:getVar(resolved) - amount)
end

-- Captured world bucket for the save schema (g4-field-save-v4). The flag
-- and variable maps are numeric (the FieldEventState shape); the RNG state
-- rides along so determinism survives a save/load cycle.
---@return table
function WorldState:capture()
  local events = self._events:serialize()
  return {
    flags = events.flags,
    variables = events.vars,
    objects = {},
    rng = self.rng:serialize(),
  }
end

-- Rebuild the rng from a captured world bucket; the event state itself is
-- restored by the game layer (it owns the save's authoritative flags). A
-- present rng value must be valid serialized state: silently dropping it
-- would break determinism across the load.
---@param world table
function WorldState:restoreRng(world)
  assert(type(world) == "table", "world bucket must be a table")
  if world.rng ~= nil then
    local ok, rng = pcall(ScriptRng.restore, world.rng)
    if not ok then
      Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "serialized rng state is malformed", { rng = world.rng })
    end
    self.rng = rng
  end
end

---@param record table
---@param opts table|nil
---@return WorldState
function WorldState.restore(record, opts)
  local valid, err = WorldState.validate(record)
  if not valid then
    local validationError = assert(err)
    Errors.raise(validationError.code, validationError.message, validationError.context)
  end
  local validated = assert(valid)
  local events = { flags = validated.flags, vars = validated.variables }
  local rng = ScriptRng.restore(validated.rng)
  return WorldState.new({ events = events, catalogs = opts and opts.catalogs, rng = rng })
end

-- The numeric event store (used by the actor layer and diagnostics).
---@return FieldEventState
function WorldState:events()
  return self._events
end

return WorldState
