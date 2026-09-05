-- Owns committed tile occupancy and autonomous destination reservations.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class FieldActorOccupancy
---@field runtimeMap RuntimeFieldMap
---@field managerSlot fun(self: FieldActorOccupancy, actor: FieldActorManager.Actor): integer
local FieldActorOccupancy = {}
FieldActorOccupancy.__index = FieldActorOccupancy

---@class FieldActorOccupancy.State
---@field occupied table<string, FieldActorManager.Actor[]>
---@field reservations table<string, { actorId: string, candidate: FieldOccupancyCandidate }>

local states = setmetatable({}, { __mode = "k" })

---@param occupancy FieldActorOccupancy
---@return FieldActorOccupancy.State
local function stateOf(occupancy)
  return assert(states[occupancy], "field actor occupancy is not initialized")
end

---@param runtimeMap RuntimeFieldMap
---@param candidate FieldOccupancyCandidate
---@return string
local function keyFor(runtimeMap, candidate)
  assert(type(candidate) == "table", "occupancy candidate is required")
  if candidate.sourceSurfaceId ~= nil then
    assert(candidate.cellKey ~= nil, "stable source surface id requires a cell key")
    return string.format(
      "%d:%d:%d:source:%s:%d",
      runtimeMap.mapId,
      candidate.fieldX,
      candidate.fieldZ,
      candidate.cellKey,
      candidate.sourceSurfaceId
    )
  end
  local surfaceId = assert(candidate.surfaceId, "occupancy candidate requires a surface identity")
  local plate = assert(runtimeMap.terrain:plate(surfaceId), "occupancy candidate surface id is unknown")
  if plate.cellKey ~= nil or plate.sourceSurfaceId ~= nil then
    assert(plate.cellKey ~= nil and plate.sourceSurfaceId ~= nil, "terrain source surface identity is incomplete")
    return string.format(
      "%d:%d:%d:source:%s:%d",
      runtimeMap.mapId,
      candidate.fieldX,
      candidate.fieldZ,
      plate.cellKey,
      plate.sourceSurfaceId
    )
  end
  return string.format("%d:%d:%d:local:%d", runtimeMap.mapId, candidate.fieldX, candidate.fieldZ, surfaceId)
end

---@param bucket FieldActorManager.Actor[]?
---@param actor FieldActorManager.Actor
---@return boolean
local function contains(bucket, actor)
  if bucket == nil then
    return false
  end
  for _, candidate in ipairs(bucket) do
    if candidate == actor then
      return true
    end
  end
  return false
end

---@param options { runtimeMap: RuntimeFieldMap, managerSlot: fun(self: FieldActorOccupancy, actor: FieldActorManager.Actor): integer }
---@return FieldActorOccupancy
function FieldActorOccupancy.new(options)
  assert(
    type(options) == "table" and options.runtimeMap and options.managerSlot,
    "field actor occupancy requires owners"
  )
  local occupancy =
    setmetatable({ runtimeMap = options.runtimeMap, managerSlot = options.managerSlot }, FieldActorOccupancy)
  states[occupancy] = { occupied = {}, reservations = {} }
  return occupancy
end

---@param candidate FieldOccupancyCandidate
---@return string
function FieldActorOccupancy:key(candidate)
  return keyFor(self.runtimeMap, candidate)
end

---@param candidate FieldOccupancyCandidate
---@return FieldActorManager.Actor?
function FieldActorOccupancy:winner(candidate)
  local bucket = stateOf(self).occupied[self:key(candidate)]
  return bucket and bucket[1] or nil
end

---@param key string
---@return FieldActorManager.Actor?
function FieldActorOccupancy:winnerByKey(key)
  local bucket = stateOf(self).occupied[key]
  return bucket and bucket[1] or nil
end

---@param candidate FieldOccupancyCandidate
---@param actor FieldActorManager.Actor
---@return boolean
function FieldActorOccupancy:contains(candidate, actor)
  return contains(stateOf(self).occupied[self:key(candidate)], actor)
end

---@param key string
---@param actor FieldActorManager.Actor
---@return boolean
function FieldActorOccupancy:containsByKey(key, actor)
  return contains(stateOf(self).occupied[key], actor)
end

---@param actor FieldActorManager.Actor
---@param candidate FieldOccupancyCandidate
function FieldActorOccupancy:claim(actor, candidate)
  local state = stateOf(self)
  local key = self:key(candidate)
  local bucket = state.occupied[key]
  if bucket == nil then
    state.occupied[key] = { actor }
    return
  end
  if contains(bucket, actor) then
    return
  end
  local actorSlot = self:managerSlot(actor)
  local insertPosition = #bucket + 1
  for index, occupant in ipairs(bucket) do
    if self:managerSlot(occupant) > actorSlot then
      insertPosition = index
      break
    end
  end
  table.insert(bucket, insertPosition, actor)
end

---@param actor FieldActorManager.Actor
---@param candidate FieldOccupancyCandidate
function FieldActorOccupancy:claimExclusive(actor, candidate)
  local occupant = self:winner(candidate)
  if occupant ~= nil and occupant ~= actor then
    Errors.raise(
      FieldErrors.ACTOR_OCCUPANCY_CONFLICT,
      actor.actorId .. " cannot claim " .. occupant.actorId .. "'s field cell",
      { actorId = actor.actorId, otherActorId = occupant.actorId, mapId = self.runtimeMap.mapId }
    )
  end
  self:claim(actor, candidate)
end

---@param actor FieldActorManager.Actor
---@param candidate FieldOccupancyCandidate
function FieldActorOccupancy:release(actor, candidate)
  local state = stateOf(self)
  local key = self:key(candidate)
  local bucket = state.occupied[key]
  if bucket == nil then
    return
  end
  for index, occupant in ipairs(bucket) do
    if occupant == actor then
      table.remove(bucket, index)
      if #bucket == 0 then
        state.occupied[key] = nil
      end
      return
    end
  end
end

---@param actor FieldActorManager.Actor
---@param key string
function FieldActorOccupancy:releaseByKey(actor, key)
  local state = stateOf(self)
  local bucket = state.occupied[key]
  if bucket == nil then
    return
  end
  for index, occupant in ipairs(bucket) do
    if occupant == actor then
      table.remove(bucket, index)
      if #bucket == 0 then
        state.occupied[key] = nil
      end
      return
    end
  end
end

---@param actor FieldActorManager.Actor
---@param oldCandidate FieldOccupancyCandidate?
---@param newCandidate FieldOccupancyCandidate?
function FieldActorOccupancy:move(actor, oldCandidate, newCandidate)
  local oldKey = oldCandidate and self:key(oldCandidate) or nil
  local newKey = newCandidate and self:key(newCandidate) or nil
  if oldKey == newKey then
    if newCandidate ~= nil and not self:contains(newCandidate, actor) then
      self:claim(actor, newCandidate)
    end
    return
  end
  if oldCandidate ~= nil then
    self:release(actor, oldCandidate)
  end
  if newCandidate ~= nil then
    self:claim(actor, newCandidate)
  end
end

---@param actorId string
---@param candidate FieldOccupancyCandidate
---@return string
function FieldActorOccupancy:reserve(actorId, candidate)
  local state = stateOf(self)
  local key = self:key(candidate)
  assert(state.reservations[key] == nil, "occupancy reservation is already claimed")
  assert(state.occupied[key] == nil or #state.occupied[key] == 0, "occupancy reservation targets an occupied cell")
  state.reservations[key] = { actorId = actorId, candidate = candidate }
  return key
end

---@param candidate FieldOccupancyCandidate
---@return { actorId: string, candidate: FieldOccupancyCandidate }?
function FieldActorOccupancy:reservation(candidate)
  return stateOf(self).reservations[self:key(candidate)]
end

---@param candidate FieldOccupancyCandidate
---@param actorId string?
function FieldActorOccupancy:cancelReservation(candidate, actorId)
  local state = stateOf(self)
  local key = self:key(candidate)
  local reservation = state.reservations[key]
  if reservation == nil then
    return
  end
  if actorId ~= nil then
    assert(reservation.actorId == actorId, "occupancy reservation owner disagrees on cancellation")
  end
  state.reservations[key] = nil
end

---@param key string
---@return { actorId: string, candidate: FieldOccupancyCandidate }?
function FieldActorOccupancy:reservationByKey(key)
  return stateOf(self).reservations[key]
end

---@param key string
---@param actorLookup fun(actorId: string): FieldActorManager.Actor?
---@return FieldActorManager.Actor?
function FieldActorOccupancy:reservedActor(key, actorLookup)
  local reservation = assert(stateOf(self).reservations[key], "occupancy reservation is missing")
  return assert(actorLookup(reservation.actorId), "autonomous reservation actor is missing")
end

---@param actor FieldActorManager.Actor
---@return integer
function FieldActorOccupancy:managerSlot(actor)
  return self.managerSlot(self, actor)
end

return FieldActorOccupancy
