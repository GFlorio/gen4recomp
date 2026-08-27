-- Owns logical field-map preparation and residency around the committed
-- physical coverage. Map loading, actor storage, and physical-cell ownership
-- remain with their existing owners; this module only coordinates membership
-- and transaction order.

---@class FieldResidencyCoordinator
---@field coverage FieldCoverage?
---@field mapLoader FieldMapLoader
---@field actors FieldActorManager
---@field zoneController FieldZoneController
---@field eventState FieldEventState
---@field composeMap fun(runtimeMap: RuntimeFieldMap): RuntimeFieldMap
---@field onPreparedMap fun(runtimeMap: RuntimeFieldMap)?
---@field residents table<integer, { runtimeMap: RuntimeFieldMap }>
---@field prepared table<integer, FieldActorManager.PreparedMap>
---@field synchronousLogicalFallbackLoads integer
---@field initialized boolean
---@field disposed boolean
local FieldResidencyCoordinator = {}
FieldResidencyCoordinator.__index = FieldResidencyCoordinator

---@class FieldResidencyPlayer
---@field fieldX integer
---@field fieldZ integer
---@field currentMap RuntimeFieldMap

local function sortedIds(descriptors)
  local seen = {}
  for _, descriptor in ipairs(descriptors) do
    assert(type(descriptor.mapHeaderId) == "number", "field cell map header is missing")
    seen[descriptor.mapHeaderId] = true
  end
  local result = {}
  for mapId in pairs(seen) do
    result[#result + 1] = mapId
  end
  table.sort(result)
  return result
end

---@param options table
---@return FieldResidencyCoordinator
function FieldResidencyCoordinator.new(options)
  assert(type(options) == "table", "field residency coordinator options required")
  assert(options.coverage or options.mapLoader, "field residency coordinator map owner required")
  assert(options.mapLoader and options.actors and options.zoneController, "field residency coordinator owners required")
  assert(options.eventState, "field residency coordinator event state required")
  return setmetatable({
    coverage = options.coverage,
    mapLoader = options.mapLoader,
    actors = options.actors,
    zoneController = options.zoneController,
    eventState = options.eventState,
    composeMap = options.composeMap or function(runtimeMap)
      return runtimeMap
    end,
    onPreparedMap = options.onPreparedMap,
    residents = {},
    prepared = {},
    synchronousLogicalFallbackLoads = 0,
    initialized = false,
    disposed = false,
  }, FieldResidencyCoordinator)
end

function FieldResidencyCoordinator:_protect(mapId, protected)
  self.mapLoader:protectMap(mapId, protected)
end

function FieldResidencyCoordinator:_prepare(mapId)
  assert(not self.residents[mapId] and not self.prepared[mapId], "logical map is already owned")
  local logicalMap = self.mapLoader:load(mapId)
  local runtimeMap = self.composeMap(logicalMap)
  self:_protect(mapId, true)
  local ok, prepared = pcall(self.actors.prepareMap, self.actors, runtimeMap, self.eventState)
  if not ok then
    self:_protect(mapId, false)
    error(prepared, 0)
  end
  local actorPreparation = assert(prepared)
  self.prepared[mapId] = actorPreparation
  if self.onPreparedMap then
    local hookOk, hookErr = pcall(self.onPreparedMap, runtimeMap)
    if not hookOk then
      self.actors:discardPrepared(actorPreparation)
      self.prepared[mapId] = nil
      self:_protect(mapId, false)
      error(hookErr, 0)
    end
  end
end

function FieldResidencyCoordinator:_promote(mapId)
  local prepared = self.prepared[mapId]
  if not prepared then
    return false
  end
  local ok, err = pcall(self.actors.commitPrepared, self.actors, prepared)
  if not ok then
    if prepared.state == "prepared" then
      self.actors:discardPrepared(prepared)
    end
    self.prepared[mapId] = nil
    self:_protect(mapId, false)
    error(err, 0)
  end
  self.prepared[mapId] = nil
  self.residents[mapId] = { runtimeMap = prepared.entry.runtimeMap }
  return true
end

function FieldResidencyCoordinator:_ensureResident(mapId, countFallback)
  if self.residents[mapId] then
    return
  end
  if self:_promote(mapId) then
    return
  end
  self:_prepare(mapId)
  if countFallback then
    self.synchronousLogicalFallbackLoads = self.synchronousLogicalFallbackLoads + 1
  end
  assert(self:_promote(mapId))
end

function FieldResidencyCoordinator:_committedMapIds(anchorX, anchorZ)
  if not self.coverage then
    return {}
  end
  local descriptors
  if anchorX == nil or anchorZ == nil or type(self.coverage.descriptorsFor) ~= "function" then
    descriptors = self.coverage:committedDescriptors()
  else
    descriptors = self.coverage:descriptorsFor(anchorX, anchorZ)
  end
  if not descriptors then
    descriptors = self.coverage:committedDescriptors()
  end
  return sortedIds(descriptors)
end

function FieldResidencyCoordinator:_prefetchMapIds()
  if not self.coverage then
    return {}
  end
  local descriptors
  if type(self.coverage.prefetchDescriptors) == "function" then
    descriptors = self.coverage:prefetchDescriptors()
  else
    descriptors = self.coverage:committedDescriptors()
  end
  if not descriptors then
    descriptors = self.coverage:committedDescriptors()
  end
  return sortedIds(descriptors)
end

---@return FieldResidencyCoordinator
function FieldResidencyCoordinator:initialize()
  assert(not self.disposed and not self.initialized, "field residency coordinator is not initializable")
  local required = self:_committedMapIds()
  if not self.coverage and self.actors.currentMapId ~= nil then
    local mapId = assert(self.actors.currentMapId)
    local residentEntry = assert(self.actors.maps[mapId])
    local residents = assert(self.residents)
    residents[mapId] = { runtimeMap = assert(residentEntry.runtimeMap) }
    self:_protect(mapId, true)
  end
  for _, mapId in ipairs(required) do
    if self.actors.maps[mapId] then
      self.residents[mapId] = { runtimeMap = self.actors.maps[mapId].runtimeMap }
      self:_protect(mapId, true)
    else
      self:_ensureResident(mapId, false)
    end
  end
  if self.actors.currentMapId == nil and #required > 0 then
    self.actors:setActiveMap(required[1])
  end
  self.actors:reconcilePhysicalWorld()
  self.initialized = true
  if self.coverage then
    self.coverage:queuePrefetch()
  end
  return self
end

---@param maxItems integer
---@return integer
function FieldResidencyCoordinator:updatePrefetch(maxItems)
  assert(not self.disposed and self.initialized, "field residency coordinator is not ready")
  assert(type(maxItems) == "number" and maxItems >= 0 and maxItems % 1 == 0)
  local completed = 0
  if self.coverage then
    completed = self.coverage:updatePrefetch(maxItems)
    if completed == maxItems or maxItems == 0 then
      return completed
    end
    if self.coverage:status().prefetchError then
      return completed
    end
  end
  local prepared = 0
  local remaining = maxItems - completed
  for _, mapId in ipairs(self:_prefetchMapIds()) do
    if not self.residents[mapId] and not self.prepared[mapId] then
      if prepared >= remaining then
        break
      end
      self:_prepare(mapId)
      prepared = prepared + 1
      if prepared >= remaining then
        break
      end
    end
  end
  return completed + prepared
end

function FieldResidencyCoordinator:_release(mapId)
  local prepared = self.prepared[mapId]
  if prepared then
    if prepared.state == "prepared" then
      self.actors:discardPrepared(prepared)
    end
    self.prepared[mapId] = nil
    self:_protect(mapId, false)
    return
  end
  if self.residents[mapId] then
    self.actors:leaveMap(mapId)
    self.residents[mapId] = nil
    self:_protect(mapId, false)
  end
end

---@param mapId integer
---@return RuntimeFieldMap
function FieldResidencyCoordinator:mapForId(mapId)
  assert(not self.disposed, "field residency coordinator is disposed")
  local resident = self.residents[mapId]
  if resident then
    return resident.runtimeMap
  end
  local prepared = self.prepared[mapId]
  assert(prepared, "requested map is not resident or prepared")
  return prepared.entry.runtimeMap
end

function FieldResidencyCoordinator:mapForPreflight(mapId)
  local resident = self.residents[mapId]
  if resident then
    return resident.runtimeMap
  end
  local prepared = self.prepared[mapId]
  if prepared then
    return prepared.entry.runtimeMap
  end
  -- Collision preflight is read-only. If movement outruns logical prefetch,
  -- borrow a map-loader entry without attaching actors or changing active
  -- state; the next committed boundary counts its own fallback.
  local logicalMap = self.mapLoader:load(mapId)
  self.synchronousLogicalFallbackLoads = self.synchronousLogicalFallbackLoads + 1
  return self.composeMap(logicalMap)
end

---@param player FieldResidencyPlayer
---@param context table?
---@return FieldZoneChange|table
function FieldResidencyCoordinator:afterCommittedMove(player, context)
  assert(not self.disposed and self.initialized, "field residency coordinator is not ready")
  context = context or {}
  local targetX = context.targetX or math.floor(player.fieldX / 32)
  local targetZ = context.targetZ or math.floor(player.fieldZ / 32)
  local required = self:_committedMapIds(targetX, targetZ)
  for _, mapId in ipairs(required) do
    self:_ensureResident(mapId, true)
  end
  if self.coverage and (self.coverage.anchorX ~= targetX or self.coverage.anchorZ ~= targetZ) then
    self.coverage:recenter(targetX, targetZ)
    if context.onPhysicalCommit then
      context.onPhysicalCommit(self.coverage)
    end
  end
  self.actors:reconcilePhysicalWorld()
  if self.coverage then
    local destinationId = self.coverage and self.coverage:mapHeaderAt(player.fieldX, player.fieldZ)
      or player.currentMap.mapId
    self.actors:setActiveMap(assert(destinationId))
  else
    self.actors:setActiveMap(player.currentMap.mapId)
  end
  local zoneCoverage = assert(self.coverage) --[[@as FieldZoneCoverage]]
  local zonePlayer = player --[[@as FieldZonePlayer]]
  local result = self.zoneController:afterCoverageCommit(zoneCoverage, zonePlayer)
  local requiredSet = {}
  for _, mapId in ipairs(required) do
    requiredSet[mapId] = true
  end
  local residentIds = {}
  for mapId in pairs(self.residents) do
    residentIds[#residentIds + 1] = mapId
  end
  for _, mapId in ipairs(residentIds) do
    if not requiredSet[mapId] then
      self:_release(mapId)
    end
  end
  local preparedIds = {}
  for mapId in pairs(self.prepared) do
    preparedIds[#preparedIds + 1] = mapId
  end
  for _, mapId in ipairs(preparedIds) do
    if not requiredSet[mapId] then
      self:_release(mapId)
    end
  end
  if self.coverage then
    self.coverage:queuePrefetch(targetX, targetZ)
  end
  return result or self:status()
end

---@return table
function FieldResidencyCoordinator:status()
  local residentMapIds, preparedMapIds = {}, {}
  for mapId in pairs(self.residents) do
    residentMapIds[#residentMapIds + 1] = mapId
  end
  for mapId in pairs(self.prepared) do
    preparedMapIds[#preparedMapIds + 1] = mapId
  end
  table.sort(residentMapIds)
  table.sort(preparedMapIds)
  return {
    residentMapIds = residentMapIds,
    preparedMapIds = preparedMapIds,
    synchronousLogicalFallbackLoads = self.synchronousLogicalFallbackLoads,
    physical = self.coverage and self.coverage:status() or nil,
  }
end

function FieldResidencyCoordinator:dispose()
  if self.disposed then
    return
  end
  local preparedIds = {}
  for mapId in pairs(self.prepared) do
    preparedIds[#preparedIds + 1] = mapId
  end
  for _, mapId in ipairs(preparedIds) do
    self:_release(mapId)
  end
  local residentIds = {}
  for mapId in pairs(self.residents) do
    residentIds[#residentIds + 1] = mapId
  end
  for _, mapId in ipairs(residentIds) do
    self:_release(mapId)
  end
  self.disposed = true
end

return FieldResidencyCoordinator
