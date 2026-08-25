-- Small acceptance-only movement helpers for entering generated field triggers.
-- The trigger coordinate is a source fact supplied by the scenario; its
-- adjacent standing tile is resolved from the generated collision grid.

local FieldMovement = {}

local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

---@param game table
---@param trigger { fieldX: integer, fieldZ: integer }
---@param direction string
---@return { fieldX: integer, fieldZ: integer }
function FieldMovement.standingTile(game, trigger, direction)
  local delta = assert(DELTAS[direction], "unsupported trigger direction " .. tostring(direction))
  local map = assert(game.runtime.runtimeMap, "generated runtime map required")
  local origin = assert(map.coordinateOrigin, "generated map coordinate origin required")
  local fieldX = trigger.fieldX - delta.x
  local fieldZ = trigger.fieldZ - delta.z
  local localX, localZ = fieldX - origin.x, fieldZ - origin.z
  assert(map.collision:containsLocal(localX, localZ), "trigger standing tile must be in generated collision")
  assert(not map.collision:isBlockedLocal(localX, localZ), "trigger standing tile must be walkable")
  return { fieldX = fieldX, fieldZ = fieldZ }
end

---@param game table
---@param trigger { fieldX: integer, fieldZ: integer }
---@param direction string
function FieldMovement.activate(game, trigger, direction)
  local standing = FieldMovement.standingTile(game, trigger, direction)
  game:moveTo(standing)
  game:move(direction)
  game:advanceUntil("production trigger landing", function(snapshot)
    if snapshot.mapId ~= game.runtime.runtimeMap.mapId then
      return true
    end
    return snapshot.player.fieldX == trigger.fieldX
      and snapshot.player.fieldZ == trigger.fieldZ
      and (snapshot.player.motion == "idle" or snapshot.fieldLocked)
  end, 120)
end

---@param game table
---@param directions string[]
---@return table[] snapshots
function FieldMovement.productionRoute(game, directions)
  assert(type(directions) == "table", "production route directions required")
  game:waitForFieldEntry()
  local snapshots = {}
  for index, direction in ipairs(directions) do
    local before = game:snapshot()
    game:move(direction)
    snapshots[index] = game:advanceUntil("production route move " .. tostring(index), function(snapshot)
      if snapshot.mapId ~= before.mapId then
        return true
      end
      return snapshot.player.motion == "idle"
        and (snapshot.player.fieldX ~= before.player.fieldX or snapshot.player.fieldZ ~= before.player.fieldZ)
    end, 120)
  end
  return snapshots
end

return FieldMovement
