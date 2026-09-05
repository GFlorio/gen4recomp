-- Owns active logical field-map identity and the side effects of changing it.
-- Residency and map protection belong to the coordinator.

local FieldZoneIdentity = require("libs.hgss.src.world.FieldZoneIdentity")

local FieldZoneController = {}
FieldZoneController.__index = FieldZoneController

---@class FieldZoneController
---@field currentMap RuntimeFieldMap
---@field afterCoverageCommit fun(self: FieldZoneController, coverage: FieldZoneCoverage, player: FieldZonePlayer): FieldZoneChange?
---@field mapForId fun(mapId: integer, player: FieldZonePlayer): RuntimeFieldMap?
---@field rebindScripts fun(runtimeMap: RuntimeFieldMap, player: FieldZonePlayer)
---@field applyWeather fun(runtimeMap: RuntimeFieldMap)
---@field enterAudio fun(runtimeMap: RuntimeFieldMap)
---@field lastChange table<string, unknown>?
---@field onChange fun(change: table<string, unknown>)?

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

---@param options table<string, unknown>
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
    rebindScripts = options.rebindScripts,
    applyWeather = options.applyWeather,
    enterAudio = options.enterAudio,
    onChange = options.onChange,
    lastChange = nil,
  }, FieldZoneController) --[[@as FieldZoneController]]
end

---@param self FieldZoneController
---@param coverage FieldZoneCoverage
---@param player FieldZonePlayer
---@return FieldZoneChange?
function FieldZoneController:afterCoverageCommit(coverage, player)
  assert(coverage and coverage.mapHeaderAt, "committed coverage required")
  local currentId = assert(self.currentMap and self.currentMap.mapId, "active logical map is missing")
  local destinationId = assert(
    FieldZoneIdentity.logicalZoneAt(coverage, player.fieldX, player.fieldZ, currentId),
    "player coverage cell map header is missing"
  )
  if destinationId == currentId then
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
