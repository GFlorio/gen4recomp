-- Owns field actor identity, ordering, lookup indexes, and map publication state.

---@class FieldActorStore
---@field maps table<integer, FieldActorStore.Map>
---@field currentMapId integer?
local FieldActorStore = {}
FieldActorStore.__index = FieldActorStore

---@class FieldActorStore.Map
---@field mapId integer
local Map = {}
Map.__index = Map

---@class FieldActorStore.MapState
---@field runtimeMap RuntimeFieldMap
---@field owner FieldActorStore
---@field published boolean
---@field actors table<string, FieldActorManager.Actor>
---@field order FieldActorManager.Actor[]
---@field byFlag table<integer, FieldActorEvent[]>
---@field byIndex table<integer, string>
---@field managerSlots table<integer, FieldActorManager.Actor>
---@field managerSlotByActorId table<string, integer>

local states = setmetatable({}, { __mode = "k" })

---@param store FieldActorStore
---@param mapEntry FieldActorStore.Map
---@return FieldActorStore.MapState
local function stateOf(store, mapEntry)
  local state = assert(states[mapEntry], "field actor store map is not initialized")
  assert(state.owner == store, "field actor store map is not owned by this store")
  return state
end

---@return FieldActorStore
function FieldActorStore.new()
  return setmetatable({ maps = {}, currentMapId = nil }, FieldActorStore)
end

---@param runtimeMap RuntimeFieldMap
---@return FieldActorStore.Map
function FieldActorStore:createMap(runtimeMap)
  assert(runtimeMap and runtimeMap.mapId ~= nil, "field actor store requires a runtime map")
  local mapEntry = setmetatable({ mapId = runtimeMap.mapId }, Map)
  states[mapEntry] = {
    owner = self,
    runtimeMap = runtimeMap,
    published = false,
    actors = {},
    order = {},
    byFlag = {},
    byIndex = {},
    managerSlots = {},
    managerSlotByActorId = {},
  }
  return mapEntry
end

---@param mapEntry FieldActorStore.Map
function FieldActorStore:publishMap(mapEntry)
  stateOf(self, mapEntry)
  self.maps[mapEntry.mapId] = mapEntry
end

---@param mapEntry FieldActorStore.Map
function FieldActorStore:removeMap(mapEntry)
  local state = stateOf(self, mapEntry)
  assert(next(state.actors) == nil, "cannot remove a field actor map with live actors")
  if self.maps[mapEntry.mapId] == mapEntry then
    self.maps[mapEntry.mapId] = nil
  end
  if self.maps[mapEntry.mapId] == nil and self.currentMapId == mapEntry.mapId then
    self.currentMapId = nil
  end
  states[mapEntry] = nil
end

---@param mapEntry FieldActorStore.Map
---@return RuntimeFieldMap
function FieldActorStore:runtimeMap(mapEntry)
  return stateOf(self, mapEntry).runtimeMap
end

---@param mapEntry FieldActorStore.Map
---@return boolean
function FieldActorStore:isPublished(mapEntry)
  return stateOf(self, mapEntry).published
end

---@param mapEntry FieldActorStore.Map
---@param published boolean
function FieldActorStore:setPublished(mapEntry, published)
  stateOf(self, mapEntry).published = published
end

---@param mapEntry FieldActorStore.Map
---@param event FieldActorEvent
function FieldActorStore:indexEvent(mapEntry, event)
  local state = stateOf(self, mapEntry)
  local events = state.byFlag[event.eventFlag]
  if events == nil then
    events = {}
    state.byFlag[event.eventFlag] = events
  end
  events[#events + 1] = event
end

---@param mapEntry FieldActorStore.Map
---@param eventFlag integer
---@return FieldActorEvent[]
function FieldActorStore:eventsForFlag(mapEntry, eventFlag)
  local indexed = stateOf(self, mapEntry).byFlag[eventFlag]
  if indexed == nil then
    return {}
  end
  local events = {}
  for index, event in ipairs(indexed) do
    events[index] = event
  end
  return events
end

---@param mapEntry FieldActorStore.Map
---@param actor FieldActorManager.Actor
function FieldActorStore:addActor(mapEntry, actor)
  local state = stateOf(self, mapEntry)
  assert(state.actors[actor.actorId] == nil, "field actor identity is already stored")
  assert(state.byIndex[actor.objectEventId] == nil, "field actor object index is already stored")
  state.actors[actor.actorId] = actor
  state.byIndex[actor.objectEventId] = actor.actorId
  state.order[#state.order + 1] = actor
end

---@param mapEntry FieldActorStore.Map
---@param actor FieldActorManager.Actor
function FieldActorStore:removeActor(mapEntry, actor)
  local state = stateOf(self, mapEntry)
  assert(state.actors[actor.actorId] == actor, "field actor identity disagrees on removal")
  state.actors[actor.actorId] = nil
  assert(state.byIndex[actor.objectEventId] == actor.actorId, "field actor index disagrees on removal")
  state.byIndex[actor.objectEventId] = nil
  for index, candidate in ipairs(state.order) do
    if candidate == actor then
      table.remove(state.order, index)
      return
    end
  end
  error("field actor order is missing on removal")
end

---@param mapEntry FieldActorStore.Map
---@param actorId string
---@return FieldActorManager.Actor?
function FieldActorStore:getActor(mapEntry, actorId)
  return stateOf(self, mapEntry).actors[actorId]
end

---@param mapEntry FieldActorStore.Map
---@param objectEventId integer
---@return string?
function FieldActorStore:getActorByIndex(mapEntry, objectEventId)
  return stateOf(self, mapEntry).byIndex[objectEventId]
end

---@param mapEntry FieldActorStore.Map
---@return FieldActorManager.Actor[]
function FieldActorStore:orderedActors(mapEntry)
  local order = stateOf(self, mapEntry).order
  local result = {}
  for index, actor in ipairs(order) do
    result[index] = actor
  end
  return result
end

---@param mapEntry FieldActorStore.Map
---@return FieldActorManager.Actor[]
function FieldActorStore:actorsByManagerSlot(mapEntry)
  local state = stateOf(self, mapEntry)
  local actors = {}
  for _, actor in pairs(state.actors) do
    actors[#actors + 1] = actor
  end
  table.sort(actors, function(left, right)
    return self:managerSlot(mapEntry, left) < self:managerSlot(mapEntry, right)
  end)
  return actors
end

---@param mapEntry FieldActorStore.Map
---@param actor FieldActorManager.Actor
---@param requestedSlot integer?
---@return integer
function FieldActorStore:assignManagerSlot(mapEntry, actor, requestedSlot)
  local state = stateOf(self, mapEntry)
  assert(state.managerSlotByActorId[actor.actorId] == nil, "actor already has a manager slot")
  local slot = requestedSlot
  if slot == nil then
    slot = 0
    while state.managerSlots[slot] ~= nil do
      slot = slot + 1
    end
  else
    assert(type(slot) == "number" and slot % 1 == 0 and slot >= 0, "requested manager slot is invalid")
    assert(state.managerSlots[slot] == nil, "requested manager slot is occupied")
  end
  state.managerSlots[slot] = actor
  state.managerSlotByActorId[actor.actorId] = slot
  return slot
end

---@param mapEntry FieldActorStore.Map
---@param actor FieldActorManager.Actor
---@return integer
function FieldActorStore:managerSlot(mapEntry, actor)
  local state = stateOf(self, mapEntry)
  local slot = state.managerSlotByActorId[actor.actorId]
  assert(slot ~= nil, "actor manager slot is missing for " .. tostring(actor.actorId))
  assert(state.managerSlots[slot] == actor, "actor manager slot forward map disagrees")
  return slot
end

---@param mapEntry FieldActorStore.Map
---@param actorId string
---@return boolean
function FieldActorStore:hasManagerSlot(mapEntry, actorId)
  return stateOf(self, mapEntry).managerSlotByActorId[actorId] ~= nil
end

---@param mapEntry FieldActorStore.Map
---@param actor FieldActorManager.Actor
function FieldActorStore:releaseManagerSlot(mapEntry, actor)
  local state = stateOf(self, mapEntry)
  local slot = state.managerSlotByActorId[actor.actorId]
  assert(slot ~= nil, "actor manager slot is missing on release for " .. tostring(actor.actorId))
  assert(state.managerSlots[slot] == actor, "actor manager slot forward map disagrees on release")
  state.managerSlots[slot] = nil
  state.managerSlotByActorId[actor.actorId] = nil
end

---@param mapEntry FieldActorStore.Map
---@param assignments table<integer, FieldActorManager.Actor>
function FieldActorStore:replaceManagerSlots(mapEntry, assignments)
  local state = stateOf(self, mapEntry)
  state.managerSlots = {}
  state.managerSlotByActorId = {}
  for slot, actor in pairs(assignments) do
    self:assignManagerSlot(mapEntry, actor, slot)
  end
end

---@param mapId integer?
function FieldActorStore:setCurrentMapId(mapId)
  self.currentMapId = mapId
end

return FieldActorStore
