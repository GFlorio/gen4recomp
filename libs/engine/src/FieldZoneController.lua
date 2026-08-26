-- Owns logical field-zone identity after physical coverage commits. It stages
-- destination data and actors before publishing the new logical context.

local FieldZoneController = {}
FieldZoneController.__index = FieldZoneController

---@class FieldZoneController
---@field currentMap RuntimeFieldMap
---@field afterCoverageCommit fun(self: FieldZoneController, coverage: FieldZoneCoverage, player: FieldZonePlayer): FieldZoneChange?
---@field loadMap fun(mapId: integer, player: FieldZonePlayer): RuntimeFieldMap
---@field stageActors fun(runtimeMap: RuntimeFieldMap): unknown
---@field discardActors fun(stagedActors: unknown)
---@field actorsArePrepared fun(stagedActors: unknown): boolean
---@field commitActors fun(stagedActors: unknown, destination: RuntimeFieldMap, source: RuntimeFieldMap)
---@field rebindScripts fun(runtimeMap: RuntimeFieldMap, player: FieldZonePlayer)
---@field applyWeather fun(runtimeMap: RuntimeFieldMap)
---@field enterAudio fun(runtimeMap: RuntimeFieldMap)
---@field protectMap fun(mapId: integer, protected: boolean)
---@field lastChange table?
---@field onChange fun(change: table)?

---@class FieldZoneCoverage
---@field currentCell fun(self: FieldZoneCoverage): table

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
    options.currentMap and options.loadMap and type(options.protectMap) == "function",
    "field zone controller map contract required"
  )
  return setmetatable({
    currentMap = options.currentMap,
    loadMap = options.loadMap,
    stageActors = options.stageActors,
    discardActors = options.discardActors,
    actorsArePrepared = options.actorsArePrepared,
    commitActors = options.commitActors,
    rebindScripts = options.rebindScripts,
    applyWeather = options.applyWeather,
    enterAudio = options.enterAudio,
    protectMap = options.protectMap,
    onChange = options.onChange,
    lastChange = nil,
  }, FieldZoneController) --[[@as FieldZoneController]]
end

---@param self FieldZoneController
---@param coverage FieldZoneCoverage
---@param player FieldZonePlayer
---@return FieldZoneChange?
function FieldZoneController:afterCoverageCommit(coverage, player)
  assert(coverage and coverage.currentCell, "committed coverage required")
  local cell = coverage:currentCell()
  local destinationId =
    assert(cell.mapHeaderId or (cell.descriptor and cell.descriptor.mapHeaderId), "coverage cell map header required")
  if destinationId == self.currentMap.mapId then
    return nil
  end

  local source = self.currentMap
  local destination = self.loadMap(destinationId, player)
  assert(destination and destination.mapId == destinationId, "destination logical map identity mismatch")
  local stagedActors
  local ok, err = pcall(function()
    if self.stageActors then
      stagedActors = self.stageActors(destination)
    end
  end)
  if not ok then
    if self.discardActors and stagedActors then
      self.discardActors(stagedActors)
    end
    error(err, 0)
  end

  local commitOk, commitErr = pcall(function()
    if self.commitActors then
      self.commitActors(stagedActors, destination, source)
    end
  end)
  if not commitOk then
    if self.discardActors and self.actorsArePrepared and stagedActors and self.actorsArePrepared(stagedActors) then
      self.discardActors(stagedActors)
    end
    error(commitErr, 0)
  end
  self.protectMap(destination.mapId, true)
  self.protectMap(source.mapId, false)
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
