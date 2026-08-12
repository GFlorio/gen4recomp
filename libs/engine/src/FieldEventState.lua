-- Numeric field event-flag and variable store. HGSS object events are created
-- only while their event flag is clear (pret/pokeheartgold `src/map_object.c`,
-- `MapObjectManager_CreateFromEventData`), so this store is the authority for
-- actor visibility as well as for later script state. Keys and values are
-- unsigned 16-bit integers with clear/zero defaults; no symbolic decomp name is
-- required at runtime. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")

---@class FieldEventState
---@field private _flags table<integer, boolean>
---@field private _vars table<integer, integer>
---@field private _tick integer
---@field private _listeners fun(change: table)[]
local FieldEventState = {}
FieldEventState.__index = FieldEventState

local U16_MAX = 0xFFFF
-- Guardrail against a corrupt or hostile save allocating unbounded memory.
FieldEventState.MAX_ENTRIES = 4096

local function isU16(value)
  return type(value) == "number" and value == math.floor(value) and value >= 0 and value <= U16_MAX
end

local function requireId(code, kind, id)
  if isU16(id) then
    return id
  end
  Errors.raise(code, kind .. " id must be an unsigned 16-bit integer, got " .. tostring(id), { id = id })
end

local function copyValidated(source, idCode, kind, validateValue)
  local copy, count = {}, 0
  for id, value in pairs(source or {}) do
    requireId(idCode, kind, id)
    count = count + 1
    if count > FieldEventState.MAX_ENTRIES then
      Errors.raise(
        "EVENT_STATE_TOO_LARGE",
        kind .. " store exceeds " .. FieldEventState.MAX_ENTRIES .. " entries",
        { limit = FieldEventState.MAX_ENTRIES }
      )
    end
    copy[id] = validateValue(value, id)
  end
  return copy
end

local function validFlag(value, id)
  if value ~= true then
    Errors.raise("EVENT_FLAG_VALUE_INVALID", "flag " .. id .. " must be stored as true", { id = id, value = value })
  end
  return true
end

local function validVar(value, id)
  if not isU16(value) then
    Errors.raise(
      "EVENT_VAR_VALUE_INVALID",
      "variable " .. id .. " must hold an unsigned 16-bit integer, got " .. tostring(value),
      { id = id, value = value }
    )
  end
  return value
end

-- serialized: an optional { flags = { [u16] = true }, vars = { [u16] = u16 } }
-- snapshot, validated on the way in so a bad save fails loudly here.
function FieldEventState.new(serialized)
  serialized = serialized or {}
  assert(type(serialized) == "table", "FieldEventState.new requires a serialized table")
  return setmetatable({
    _flags = copyValidated(serialized.flags, "EVENT_FLAG_ID_INVALID", "flag", validFlag),
    _vars = copyValidated(serialized.vars, "EVENT_VAR_ID_INVALID", "variable", validVar),
    _listeners = {},
    _tick = 0,
  }, FieldEventState)
end

-- True for the simulation tick domain: a finite integer >= 0. NaN, infinities,
-- fractions, and negative values are programming errors, not runtime data.
local function isTick(tick)
  return type(tick) == "number"
    and tick == tick
    and tick ~= math.huge
    and tick ~= -math.huge
    and tick == math.floor(tick)
    and tick >= 0
end

-- The owning simulation stamps the current fixed tick so every notification
-- carries the boundary it must be applied on.
function FieldEventState:setTick(tick)
  assert(isTick(tick), "tick must be a finite nonnegative integer, got " .. tostring(tick))
  self._tick = tick
end

-- Notify against a snapshot: listeners may subscribe or unsubscribe while a
-- notification runs, and that mutation must not change which listeners see
-- this notification. Listeners subscribed at start receive it once; changes
-- apply to subsequent notifications.
function FieldEventState:_notify(change)
  change.tick = self._tick
  local snapshot = {}
  for i = 1, #self._listeners do
    snapshot[i] = self._listeners[i]
  end
  for _, listener in ipairs(snapshot) do
    listener(change)
  end
end

function FieldEventState:isFlagSet(flagId)
  return self._flags[requireId("EVENT_FLAG_ID_INVALID", "flag", flagId)] == true
end

function FieldEventState:_writeFlag(flagId, value)
  flagId = requireId("EVENT_FLAG_ID_INVALID", "flag", flagId)
  local old = self._flags[flagId] == true
  if old == value then
    return
  end
  self._flags[flagId] = value or nil
  self:_notify({ kind = "flag", id = flagId, oldValue = old, newValue = value })
end

function FieldEventState:setFlag(flagId)
  self:_writeFlag(flagId, true)
end

function FieldEventState:clearFlag(flagId)
  self:_writeFlag(flagId, false)
end

function FieldEventState:getVar(varId)
  return self._vars[requireId("EVENT_VAR_ID_INVALID", "variable", varId)] or 0
end

function FieldEventState:setVar(varId, value)
  varId = requireId("EVENT_VAR_ID_INVALID", "variable", varId)
  validVar(value, varId)
  local old = self._vars[varId] or 0
  if old == value then
    return
  end
  self._vars[varId] = value ~= 0 and value or nil
  self:_notify({ kind = "var", id = varId, oldValue = old, newValue = value })
end

function FieldEventState:subscribe(listener)
  assert(type(listener) == "function", "subscribe requires a listener function")
  local listeners = self._listeners
  listeners[#listeners + 1] = listener
  return function()
    for index, entry in ipairs(listeners) do
      if entry == listener then
        table.remove(listeners, index)
        return
      end
    end
  end
end

function FieldEventState:serialize()
  local flags, vars = {}, {}
  for id in pairs(self._flags) do
    flags[id] = true
  end
  for id, value in pairs(self._vars) do
    vars[id] = value
  end
  return { flags = flags, vars = vars }
end

return FieldEventState
