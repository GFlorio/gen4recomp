-- Resolves field events that are evaluated outside the Action-facing-cell
-- path. Coordinate events follow HGSS's X/Z rectangle and variable predicate;
-- passive signs are the north-facing type-one background path. This module is
-- pure and does not start scripts or mutate field state.

local FieldEventResolver = {}

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
---@param player table
---@param eventState FieldEventState
---@return table?
function FieldEventResolver.resolveCoordinate(runtimeMap, player, eventState)
  assert(runtimeMap and runtimeMap.fieldData and runtimeMap.fieldData.events, "coordinate events required")
  assert(player and player.fieldX and player.fieldZ and player.facing, "coordinate player state required")
  assert(eventState and eventState.getVar, "coordinate event state required")
  local events = assert(runtimeMap.fieldData.events.coordinates, "coordinate event collection required")
  for _, event in ipairs(events) do
    if
      event.scriptId ~= 0
      and player.fieldX >= event.x
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
---@param player table
---@return table?
function FieldEventResolver.resolvePassiveSign(runtimeMap, player)
  assert(runtimeMap and runtimeMap.fieldData and runtimeMap.fieldData.events, "background events required")
  assert(player and player.fieldX and player.fieldZ and player.facing, "passive-sign player state required")
  if player.facing ~= "north" then
    return nil
  end
  local targetX, targetZ = player.fieldX, player.fieldZ - 1
  local events = assert(runtimeMap.fieldData.events.background, "background event collection required")
  for _, event in ipairs(events) do
    if event.x == targetX and event.z == targetZ and event.type == 1 and event.scriptId ~= 0 then
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
