-- Small acceptance-only movement helpers for entering generated field triggers.
-- The trigger coordinate is a source fact supplied by the scenario; its
-- adjacent standing tile is resolved from the generated collision grid.
--
-- Route planning (FieldMovement.route) never reimplements collision/terrain
-- rules: each candidate step is asked of a disposable `FieldPlayer` clone,
-- sharing the live player's occupancy predicate, so a planned route can
-- never enter a tile production movement would itself reject.

local FieldPlayer = require("libs.engine.src.FieldPlayer")

local FieldMovement = {}

local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local DIRECTIONS = { "east", "north", "south", "west" }

local function isWarpTile(map, fieldX, fieldZ)
  for _, warp in ipairs(map.fieldData.events.warps) do
    if warp.x == fieldX and warp.z == fieldZ then
      return true
    end
  end
  return false
end

-- A disposable production `FieldPlayer` standing at the given node, sharing
-- the live player's map and occupancy predicate. Only used to ask
-- `resolveStep`; it is discarded immediately after.
local function probeAt(map, occupancy, node)
  return FieldPlayer.new({
    currentMap = map,
    fieldX = node.fieldX,
    fieldZ = node.fieldZ,
    surfaceId = node.surfaceId,
    occupancy = occupancy,
  })
end

-- Plan a route to `target` using the exact production step-resolution rule
-- (`FieldPlayer:resolveStep`): map collision, terrain/surface crossing, and
-- live actor occupancy. Live actors are assumed stationary for the duration
-- of the search (true unless the scenario itself drives a script mid-plan).
-- A warp tile is only enterable as the final target, never as a
-- pass-through, matching the older BFS's warp-avoidance contract.
---@param game table an AcceptanceHarness game
---@param target { fieldX: integer, fieldZ: integer }
---@return { direction: string, fieldX: integer, fieldZ: integer, surfaceId: integer }[]|nil
function FieldMovement.route(game, target)
  local player = assert(game.runtime.player, "acceptance movement requires a live player")
  local map = assert(player.currentMap, "acceptance movement map required")
  local occupancy = player.occupancy
  local targetKey = target.fieldX .. ":" .. target.fieldZ

  local start = { fieldX = player.fieldX, fieldZ = player.fieldZ, surfaceId = player.surfaceId, route = {} }
  local seen = { [start.fieldX .. ":" .. start.fieldZ] = true }
  local queue = { start }
  local head = 1
  while queue[head] do
    local node = queue[head]
    head = head + 1
    if node.fieldX .. ":" .. node.fieldZ == targetKey then
      return node.route
    end
    local probe = probeAt(map, occupancy, node)
    for _, direction in ipairs(DIRECTIONS) do
      local destination = probe:resolveStep(direction)
      if destination then
        local key = destination.fieldX .. ":" .. destination.fieldZ
        if not seen[key] and (key == targetKey or not isWarpTile(map, destination.fieldX, destination.fieldZ)) then
          seen[key] = true
          local nextRoute = {}
          for index, step in ipairs(node.route) do
            nextRoute[index] = step
          end
          nextRoute[#nextRoute + 1] = {
            direction = direction,
            fieldX = destination.fieldX,
            fieldZ = destination.fieldZ,
            surfaceId = destination.surfaceId,
          }
          queue[#queue + 1] = {
            fieldX = destination.fieldX,
            fieldZ = destination.fieldZ,
            surfaceId = destination.surfaceId,
            route = nextRoute,
          }
        end
      end
    end
  end
  return nil
end

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
