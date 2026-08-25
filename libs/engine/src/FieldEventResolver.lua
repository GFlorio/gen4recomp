-- Resolves field events that are evaluated outside the Action-facing-cell
-- path. Coordinate events follow HGSS's X/Z rectangle and variable predicate;
-- passive signs are the north-facing type-one background path. This module is
-- pure and does not start scripts or mutate field state.

local FieldEventResolver = {}

---@class FieldCoordinateEvent
---@field index integer
---@field x integer
---@field z integer
---@field width integer
---@field height integer
---@field variableId integer
---@field requiredValue integer
---@field scriptId integer

---@class FieldBackgroundEvent
---@field index integer
---@field x integer
---@field z integer
---@field type integer
---@field directionRaw integer
---@field scriptId integer

---@class FieldEventCollections
---@field coordinates FieldCoordinateEvent[]
---@field background FieldBackgroundEvent[]

---@class FieldEventData
---@field events FieldEventCollections

---@class FieldCoordinateIntent
---@field index integer
---@field eventIndex integer
---@field event FieldCoordinateEvent

---@class FieldBackgroundIntent
---@field eventIndex integer
---@field type integer
---@field direction integer

---@class FieldEventIntent
---@field kind "coordinate"|"background"
---@field mapId integer
---@field sourceFieldX integer
---@field sourceFieldZ integer
---@field targetFieldX integer
---@field targetFieldZ integer
---@field playerFacing FieldDirection
---@field scriptId integer
---@field object nil
---@field background FieldBackgroundIntent?
---@field coordinate FieldCoordinateIntent?
---@field coordinateId integer?

---@param kind "coordinate"|"background"
---@param runtimeMap RuntimeFieldMap
---@param player FieldPlayer
---@param targetX integer
---@param targetZ integer
---@param scriptId integer
---@return FieldEventIntent
local function baseIntent(kind, runtimeMap, player, targetX, targetZ, scriptId)
  return {
    kind = kind,
    mapId = runtimeMap.mapId,
    sourceFieldX = player.fieldX,
    sourceFieldZ = player.fieldZ,
    targetFieldX = targetX,
    targetFieldZ = targetZ,
    playerFacing = player.facing,
    scriptId = scriptId,
    object = nil,
    background = nil,
    coordinate = nil,
  }
end

---@param runtimeMap RuntimeFieldMap
---@param player FieldPlayer
---@param eventState FieldEventState
---@return FieldEventIntent?
function FieldEventResolver.resolveCoordinate(runtimeMap, player, eventState)
  assert(runtimeMap and runtimeMap.fieldData and runtimeMap.fieldData.events, "coordinate events required")
  assert(player and player.fieldX and player.fieldZ and player.facing, "coordinate player state required")
  assert(eventState and eventState.getVar, "coordinate event state required")
  local fieldData = runtimeMap.fieldData ---@cast fieldData FieldEventData
  local events = assert(fieldData.events.coordinates, "coordinate event collection required")
  for _, event in ipairs(events) do
    if
      player.fieldX >= event.x
      and player.fieldX < event.x + event.width
      and player.fieldZ >= event.z
      and player.fieldZ < event.z + event.height
      and eventState:getVar(event.variableId) == event.requiredValue
    then
      local intent = baseIntent("coordinate", runtimeMap, player, player.fieldX, player.fieldZ, event.scriptId)
      intent.coordinate = { index = event.index, eventIndex = event.index, event = event }
      intent.coordinateId = event.index
      return intent
    end
  end
  return nil
end

---@param runtimeMap RuntimeFieldMap
---@param player FieldPlayer
---@return FieldEventIntent?
function FieldEventResolver.resolvePassiveSign(runtimeMap, player)
  assert(runtimeMap and runtimeMap.fieldData and runtimeMap.fieldData.events, "background events required")
  assert(player and player.fieldX and player.fieldZ and player.facing, "passive-sign player state required")
  if player.facing ~= "north" then
    return nil
  end
  local targetX, targetZ = player.fieldX, player.fieldZ - 1
  local fieldData = runtimeMap.fieldData ---@cast fieldData FieldEventData
  local events = assert(fieldData.events.background, "background event collection required")
  for _, event in ipairs(events) do
    if event.x == targetX and event.z == targetZ and event.type == 1 then
      local intent = baseIntent("background", runtimeMap, player, targetX, targetZ, event.scriptId)
      intent.background = {
        eventIndex = event.index,
        type = event.type,
        direction = event.directionRaw,
      }
      return intent
    end
  end
  return nil
end

return FieldEventResolver
