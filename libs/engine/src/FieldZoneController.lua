-- Owns active logical field-map identity and the side effects of changing it.
-- Residency and map protection belong to the coordinator.

local FieldZoneController = {}
FieldZoneController.__index = FieldZoneController

---@class FieldZoneController
---@field currentMap RuntimeFieldMap
---@field afterCoverageCommit fun(self: FieldZoneController, coverage: FieldZoneCoverage, player: FieldZonePlayer): FieldZoneChange?
---@field mapForPreflight fun(self: FieldZoneController, mapId: integer, player: FieldZonePlayer|FieldPlayer): RuntimeFieldMap
---@field mapForId fun(mapId: integer, player: FieldZonePlayer|FieldPlayer): RuntimeFieldMap?
---@field mapForPreflightId fun(mapId: integer, player: FieldZonePlayer|FieldPlayer): RuntimeFieldMap?
---@field rebindScripts fun(runtimeMap: RuntimeFieldMap, player: FieldZonePlayer)
---@field applyWeather fun(runtimeMap: RuntimeFieldMap)
---@field enterAudio fun(runtimeMap: RuntimeFieldMap)
---@field lastChange table?
---@field onChange fun(change: table)?

---@class FieldZoneCoverage
---@field mapHeaderAt fun(self: FieldZoneCoverage, fieldX: integer, fieldZ: integer): integer?

---@class FieldZonePlayer
---@field fieldX integer
---@field fieldZ integer

---@class FieldZoneChange
---@field oldMapId integer
---@field newMapId integer
---@field oldMapSection string
---@field newMapSection string
---@field mapSectionChanged boolean

---@param options table
---@return FieldZoneController
function FieldZoneController.new(options)
  assert(type(options) == "table", "field zone controller options required")
  assert(
    options.currentMap and type(options.mapForId) == "function",
    "field zone controller resident map contract required"
  )
  return setmetatable({
    currentMap = options.currentMap,
    mapForId = options.mapForId,
    mapForPreflightId = options.mapForPreflightId or options.mapForId,
    rebindScripts = options.rebindScripts,
    applyWeather = options.applyWeather,
    enterAudio = options.enterAudio,
    onChange = options.onChange,
    lastChange = nil,
  }, FieldZoneController) --[[@as FieldZoneController]]
end

-- Load or compose a logical destination view for collision preflight. The
-- returned map is borrowed by the caller; this method never publishes zone
-- state or invokes any actor/transition side effects.
---@param mapId integer
---@param player FieldZonePlayer|FieldPlayer
---@return RuntimeFieldMap
function FieldZoneController:mapForPreflight(mapId, player)
  assert(type(mapId) == "number", "preflight map id required")
  assert(player, "preflight player required")
  if mapId == self.currentMap.mapId then
    return self.currentMap
  end
  local destination = self.mapForPreflightId(mapId, player)
  assert(destination and destination.mapId == mapId, "preflight logical map is not resident or prepared")
  return destination
end

---@param self FieldZoneController
---@param coverage FieldZoneCoverage
---@param player FieldZonePlayer
---@return FieldZoneChange?
function FieldZoneController:afterCoverageCommit(coverage, player)
  assert(coverage and coverage.mapHeaderAt, "committed coverage required")
  local destinationId =
    assert(coverage:mapHeaderAt(player.fieldX, player.fieldZ), "player coverage cell map header is missing")
  if destinationId == self.currentMap.mapId then
    return nil
  end

  local source = self.currentMap
  local destination = self.mapForId(destinationId, player)
  assert(destination and destination.mapId == destinationId, "destination logical map is not resident")
  self.currentMap = destination
  if self.rebindScripts then
    self.rebindScripts(destination, player)
  end
  if self.applyWeather then
    self.applyWeather(destination)
  end
  if self.enterAudio then
    self.enterAudio(destination)
  end
  local change = {
    oldMapId = source.mapId,
    newMapId = destination.mapId,
    oldMapSection = source.mapSection,
    newMapSection = destination.mapSection,
    mapSectionChanged = source.mapSection ~= destination.mapSection,
  } ---@type FieldZoneChange
  self.lastChange = change
  if self.onChange then
    self.onChange(change)
  end
  return change
end

return FieldZoneController
