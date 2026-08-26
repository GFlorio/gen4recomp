-- Script execution environment: one serializable holder for the three stable
-- context slots, the shared movement generation state, caller signals, and
-- owner-counted locks. A foreground root owns one environment; verified
-- `call_common` children occupy later slots (1..2) of the same environment.
-- Slots are visited deterministically 0..2, and the slot loop is dynamic so a
-- child created in a later, not-yet-visited slot can receive its initial run
-- in the caller's tick. The lock model follows the source field rules: locks
-- are owner-counted by script instance, and ending, cancelling, or faulting
-- an instance releases every lock it owns. Pure domain module: no love
-- dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

---@class ScriptEnvironment
---@field environmentId string
---@field mode string foreground|background
---@field rootInstanceId string|nil
---@field contextSlots table<integer, string>
---@field movementGeneration integer
---@field movementTasksByGeneration table<integer, table<string, boolean>>
---@field callerSignals table<integer, boolean>
---@field locks table
---@field createdAtTick integer
local ScriptEnvironment = {}
ScriptEnvironment.__index = ScriptEnvironment

ScriptEnvironment.SCHEMA_NAME = "g4-script-environment-v1"
ScriptEnvironment.SLOT_COUNT = 3

-- Lock kinds shared with the runtime handlers: "player" (movement + new
-- interaction triggers), "autonomous" (suspended autonomous field-object
-- behavior), and "actor:<ref>" (exclusive scripted-movement ownership for one
-- actor).
ScriptEnvironment.LOCK_PLAYER = "player"
ScriptEnvironment.LOCK_AUTONOMOUS = "autonomous"
ScriptEnvironment.LOCK_ACTOR_PREFIX = "actor:"
local LOCK_PLAYER = ScriptEnvironment.LOCK_PLAYER
local LOCK_AUTONOMOUS = ScriptEnvironment.LOCK_AUTONOMOUS
local LOCK_ACTOR_PREFIX = ScriptEnvironment.LOCK_ACTOR_PREFIX

---@class ScriptEnvironment.CreateSpec
---@field environmentId string
---@field mode string
---@field createdAtTick integer

---@param spec ScriptEnvironment.CreateSpec
---@return ScriptEnvironment
function ScriptEnvironment.new(spec)
  assert(spec and spec.environmentId, "environment identity required")
  assert(spec.mode == "foreground" or spec.mode == "background", "environment mode must be foreground or background")
  assert(spec.createdAtTick ~= nil, "environment creation tick required")
  return setmetatable({
    environmentId = spec.environmentId,
    mode = spec.mode,
    rootInstanceId = nil,
    contextSlots = {},
    movementGeneration = 0,
    movementTasksByGeneration = { [0] = {} },
    callerSignals = {},
    locks = {},
    createdAtTick = spec.createdAtTick,
  }, ScriptEnvironment)
end

-- --- Context slots -----------------------------------------------------------

-- Place an instance into the root slot (0). The environment starts with the
-- root and may later gain verified common children.
---@param instanceId string
function ScriptEnvironment:setRoot(instanceId)
  assert(self.contextSlots[0] == nil, "root slot is already occupied")
  assert(self.rootInstanceId == nil, "environment already has a root")
  self.contextSlots[0] = instanceId
  self.rootInstanceId = instanceId
end

---@param slot integer
---@param instanceId string
function ScriptEnvironment:placeContext(slot, instanceId)
  assert(slot >= 0 and slot < ScriptEnvironment.SLOT_COUNT, "context slot out of range")
  assert(self.contextSlots[slot] == nil, "context slot " .. slot .. " is already occupied")
  self.contextSlots[slot] = instanceId
end

---@param slot integer
---@return string|nil
function ScriptEnvironment:contextAt(slot)
  return self.contextSlots[slot]
end

-- The lowest free later slot (1..2) for a verified common child, or nil when
-- the environment is exhausted.
---@param callerSlot integer
---@return integer|nil
function ScriptEnvironment:freeChildSlot(callerSlot)
  for slot = callerSlot + 1, ScriptEnvironment.SLOT_COUNT - 1 do
    if self.contextSlots[slot] == nil then
      return slot
    end
  end
  return nil
end

-- Free one context slot when its instance ends; the root's slot is freed by
-- environment teardown, not here.
---@param slot integer
function ScriptEnvironment:clearContext(slot)
  assert(slot > 0, "the root slot is cleared with the environment")
  self.contextSlots[slot] = nil
end

-- --- Movement generations ----------------------------------------------------

-- Movement launched by a script belongs to the environment's current
-- generation; the barrier watches the generation predicate. When the barrier
-- completes during task polling, the environment advances to the next
-- generation before any context runs.
---@return integer
function ScriptEnvironment:currentGeneration()
  return self.movementGeneration
end

---@param taskId string
function ScriptEnvironment:registerMovementTask(taskId)
  local generation = self.movementGeneration
  local set = self.movementTasksByGeneration[generation]
  if set == nil then
    set = {}
    self.movementTasksByGeneration[generation] = set
  end
  set[taskId] = true
end

---@param taskId string
function ScriptEnvironment:unregisterMovementTask(taskId)
  for generation, set in pairs(self.movementTasksByGeneration) do
    if set[taskId] then
      set[taskId] = nil
      return
    end
  end
end

-- The outstanding task-id set of one generation (deterministic snapshot).
---@param generation integer
---@return string[]
function ScriptEnvironment:movementTasksInGeneration(generation)
  local out = {}
  for taskId in pairs(self.movementTasksByGeneration[generation] or {}) do
    out[#out + 1] = taskId
  end
  table.sort(out)
  return out
end

-- True when the current generation still has outstanding movement.
---@return boolean
function ScriptEnvironment:hasOutstandingMovement()
  return next(self.movementTasksByGeneration[self.movementGeneration] or {}) ~= nil
end

-- Advance to the next movement generation; any movement started later belongs
-- to it.
function ScriptEnvironment:advanceMovementGeneration()
  self.movementGeneration = self.movementGeneration + 1
  self.movementTasksByGeneration[self.movementGeneration] = {}
end

-- --- Caller signals ----------------------------------------------------------

-- `call_common` sets the caller's signal bit; a translated `signal_caller`
-- inside a verified common child at slot N clears bit N - 1 (its parent),
-- matching the source CallStd protocol (pret/pokeheartgold src/scrcmd_c.c
-- ScrCmd_CallStd / ScrCmd_RestartCurrentScript).
---@param slot integer
---@param signaled boolean
function ScriptEnvironment:setCallerSignal(slot, signaled)
  self.callerSignals[slot] = signaled
end

---@param slot integer
---@return boolean
function ScriptEnvironment:callerSignal(slot)
  return self.callerSignals[slot] == true
end

-- --- Locks -------------------------------------------------------------------

-- True for actor locks (kind "actor:<ref>").
---@param kind string
---@return boolean
local function isActorLock(kind)
  return kind:sub(1, #LOCK_ACTOR_PREFIX) == LOCK_ACTOR_PREFIX
end

-- Acquire one lock for an owning instance. Actor locks are exclusive to one
-- instance (`lockActor` grants exclusive scripted-movement ownership); any
-- other owner is a busy error.
---@param kind string
---@param ref string|nil
---@param ownerId string
function ScriptEnvironment:acquireLock(kind, ref, ownerId)
  local entry = self.locks[kind]
  if entry == nil then
    entry = { count = 0, owners = {} }
    self.locks[kind] = entry
  end
  if isActorLock(kind) and entry.count > 0 and entry.owners[ownerId] == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_ACTOR_BUSY,
      "actor is already locked by another script",
      { environmentId = self.environmentId, actor = ref, ownerId = ownerId, holder = next(entry.owners) }
    )
  end
  entry.count = entry.count + 1
  entry.owners[ownerId] = (entry.owners[ownerId] or 0) + 1
end

-- Release one lock for an owning instance; releasing a lock the instance does
-- not own is a strict-mode error.
--
-- Actor locks are the one exception (pret/pokeheartgold src/scrcmd_c.c
-- ScrCmd_Lock/ScrCmd_Release): the source command pair unconditionally
-- pauses/unpauses the named object's own movement and never tracks which
-- script issued a prior Lock. A standalone `Release <actor>` with no
-- matching `Lock <actor>` from this instance is source-valid and means
-- "resume this actor's own default autonomous movement", so it is a no-op
-- here rather than a fault when this instance holds no such lock.
---@param kind string
---@param ref string|nil
---@param ownerId string
function ScriptEnvironment:releaseLock(kind, ref, ownerId)
  local entry = self.locks[kind]
  --[[@as { count: integer, owners: table<string, integer> }|nil]]
  if entry == nil or entry.owners[ownerId] == nil then
    if isActorLock(kind) then
      return
    end
    Errors.raise(
      ScriptErrors.SCRIPT_LOCK_NOT_OWNED,
      "lock is not owned by this script instance",
      { environmentId = self.environmentId, lock = kind, ownerId = ownerId }
    )
  end
  entry = entry --[[@as { count: integer, owners: table<string, integer> }]]
  local held = assert(entry.owners[ownerId], "lock owner count invariant")
  entry.count = entry.count - 1
  entry.owners[ownerId] = held - 1
  if entry.owners[ownerId] == 0 then
    entry.owners[ownerId] = nil
  end
  if entry.count == 0 then
    self.locks[kind] = nil
  end
end

-- The current count for one lock kind (0 when absent).
---@param kind string
---@return integer
function ScriptEnvironment:lockCount(kind)
  local entry = self.locks[kind]
  return entry and entry.count or 0
end

---@return boolean
function ScriptEnvironment:playerLocked()
  return self:lockCount(LOCK_PLAYER) > 0
end

---@return boolean
function ScriptEnvironment:autonomousLocked()
  return self:lockCount(LOCK_AUTONOMOUS) > 0
end

-- Release every lock an owning instance holds (ending, cancelling, or
-- faulting an instance releases all its locks).
---@param ownerId string
function ScriptEnvironment:releaseLocksFor(ownerId)
  for key, entry in pairs(self.locks) do
    if entry.owners[ownerId] ~= nil then
      entry.count = entry.count - entry.owners[ownerId]
      entry.owners[ownerId] = nil
      if entry.count == 0 then
        self.locks[key] = nil
      end
    end
  end
end

-- Deterministic serialization: only the owner-counted lock map survives.
-- Absolute runtime ticks are diagnostics; the creation tick becomes a
-- relative delay rebased at capture time `captureTick`.
---@param captureTick integer
---@return table
function ScriptEnvironment:capture(captureTick)
  assert(captureTick ~= nil, "capture tick required")
  local locks = {}
  for key, entry in pairs(self.locks) do
    locks[key] = { count = entry.count, owners = {} }
    for ownerId, n in pairs(entry.owners) do
      locks[key].owners[ownerId] = n
    end
  end
  return {
    environmentId = self.environmentId,
    mode = self.mode,
    rootInstanceId = self.rootInstanceId,
    contextSlots = self.contextSlots,
    movementGeneration = self.movementGeneration,
    movementTasksByGeneration = self.movementTasksByGeneration,
    callerSignals = self.callerSignals,
    locks = locks,
    createdAtTick = self.createdAtTick,
    createdAtInTicks = self.createdAtTick - captureTick,
  }
end

-- Rebuild an environment from the save schema. Task references are reattached
-- by the scheduler after task records restore. `restoreTick` is the load tick;
-- the creation tick is rebased from the relative delay.
---@param record table
---@param restoreTick integer
---@return ScriptEnvironment
function ScriptEnvironment.restore(record, restoreTick)
  local environment = ScriptEnvironment.new({
    environmentId = record.environmentId,
    mode = record.mode,
    createdAtTick = restoreTick + (record.createdAtInTicks or 0),
  })
  environment.rootInstanceId = record.rootInstanceId
  environment.contextSlots = record.contextSlots or {}
  environment.movementGeneration = record.movementGeneration or 0
  environment.movementTasksByGeneration = record.movementTasksByGeneration or { [0] = {} }
  environment.callerSignals = record.callerSignals or {}
  environment.locks = record.locks or {}
  return environment
end

return ScriptEnvironment
