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
---@field residents table<integer, { logicalMap: RuntimeFieldMap, runtimeMap: RuntimeFieldMap }>
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
    synchronousLogicalFallbackLoads = 0,
    initialized = false,
    disposed = false,
  }, FieldResidencyCoordinator)
end

function FieldResidencyCoordinator:_protect(mapId, protected)
  self.mapLoader:protectMap(mapId, protected)
end

function FieldResidencyCoordinator:_acquireResident(mapId)
  assert(not self.residents[mapId], "logical map is already resident")
  local logicalMap = self.mapLoader:load(mapId)
  local protected = false
  local prepared
  local runtimeMap
  local ok, result = pcall(function()
    self:_protect(mapId, true)
    protected = true
    runtimeMap = self.composeMap(logicalMap)
    prepared = self.actors:prepareMap(assert(runtimeMap), self.eventState)
    if self.onPreparedMap then
      self.onPreparedMap(runtimeMap)
    end
    self.actors:commitPrepared(prepared)
  end)
  if not ok then
    if prepared and prepared.state == "prepared" then
      self.actors:discardPrepared(prepared)
    end
    if protected then
      self:_protect(mapId, false)
    end
    error(result, 0)
  end
  self.residents[mapId] = {
    logicalMap = logicalMap,
    runtimeMap = assert(runtimeMap),
  }
end

function FieldResidencyCoordinator:_ensureResident(mapId, countFallback)
  if self.residents[mapId] then
    return
  end
  self:_acquireResident(mapId)
  if countFallback then
    self.synchronousLogicalFallbackLoads = self.synchronousLogicalFallbackLoads + 1
  end
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

function FieldResidencyCoordinator:_prefetchMapIds(anchorX, anchorZ)
  if not self.coverage then
    return {}
  end
  local descriptors
  if type(self.coverage.prefetchDescriptors) == "function" then
    descriptors = self.coverage:prefetchDescriptors(anchorX, anchorZ)
  else
    descriptors = self.coverage:committedDescriptors()
  end
  if not descriptors then
    descriptors = self.coverage:committedDescriptors()
  end
  return sortedIds(descriptors)
end

function FieldResidencyCoordinator:_desiredReadyMapIds(anchorX, anchorZ)
  return self:_prefetchMapIds(anchorX, anchorZ)
end

function FieldResidencyCoordinator:_adoptResident(mapId, runtimeMap)
  assert(not self.residents[mapId], "logical map is already resident")
  self.residents[mapId] = {
    logicalMap = runtimeMap.logicalMap or runtimeMap,
    runtimeMap = runtimeMap,
  }
  self:_protect(mapId, true)
end

function FieldResidencyCoordinator:_syncResidentViews()
  for _, resident in pairs(self.residents) do
    if type(resident.runtimeMap.syncPhysicalFields) == "function" then
      resident.runtimeMap:syncPhysicalFields()
    end
  end
end

---@return FieldResidencyCoordinator
function FieldResidencyCoordinator:initialize()
  assert(not self.disposed and not self.initialized, "field residency coordinator is not initializable")
  local required = self:_committedMapIds()
  if not self.coverage and self.actors.currentMapId ~= nil then
    local mapId = assert(self.actors.currentMapId)
    local residentEntry = assert(self.actors.maps[mapId])
    self:_adoptResident(mapId, assert(residentEntry.runtimeMap))
  end
  for _, mapId in ipairs(required) do
    local entry = self.actors.maps[mapId]
    if entry then
      self:_adoptResident(mapId, assert(entry.runtimeMap))
    else
      self:_acquireResident(mapId)
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

---@return integer
function FieldResidencyCoordinator:updatePrefetch()
  assert(not self.disposed and self.initialized, "field residency coordinator is not ready")
  local completed = 0
  if self.coverage then
    completed = self.coverage:updatePrefetch(1)
  end
  for _, mapId in ipairs(self:_prefetchMapIds()) do
    if not self.residents[mapId] then
      self:_acquireResident(mapId)
      return completed + 1
    end
  end
  return completed
end

function FieldResidencyCoordinator:_release(mapId)
  if not self.residents[mapId] then
    return
  end
  self.actors:leaveMap(mapId)
  self.residents[mapId] = nil
  self:_protect(mapId, false)
end

---@param mapId integer
---@return RuntimeFieldMap?
function FieldResidencyCoordinator:mapForId(mapId)
  assert(not self.disposed, "field residency coordinator is disposed")
  local resident = self.residents[mapId]
  if resident then
    return resident.runtimeMap
  end
  return nil
end

function FieldResidencyCoordinator:mapForPreflight(mapId)
  local resident = self.residents[mapId]
  if resident then
    return resident.runtimeMap
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
  local anchorChanged = self.coverage and (self.coverage.anchorX ~= targetX or self.coverage.anchorZ ~= targetZ)
  if anchorChanged then
    self.coverage:recenter(targetX, targetZ)
    if context.onPhysicalCommit then
      context.onPhysicalCommit(self.coverage)
    end
    self:_syncResidentViews()
    self.actors:reconcilePhysicalWorld()
  end
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
  if anchorChanged then
    local requiredSet = {}
    for _, mapId in ipairs(self:_desiredReadyMapIds(targetX, targetZ)) do
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
    self.coverage:queuePrefetch(targetX, targetZ)
  end
  return result or self:status()
end

---@return table
function FieldResidencyCoordinator:status()
  local residentMapIds = {}
  for mapId in pairs(self.residents) do
    residentMapIds[#residentMapIds + 1] = mapId
  end
  table.sort(residentMapIds)
  return {
    residentMapIds = residentMapIds,
    synchronousLogicalFallbackLoads = self.synchronousLogicalFallbackLoads,
    physical = self.coverage and self.coverage:status() or nil,
  }
end

function FieldResidencyCoordinator:dispose()
  if self.disposed then
    return
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
