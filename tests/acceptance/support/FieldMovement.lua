-- Small acceptance-only movement helpers for entering generated field triggers.
-- The trigger coordinate is a source fact supplied by the scenario; its
-- adjacent standing tile is resolved from the generated collision grid.
--
-- Route planning (FieldMovement.route) never reimplements collision/terrain
-- rules: each candidate step is asked of a disposable `FieldPlayer` clone,
-- sharing the live player's occupancy predicate, so a planned route can
-- never enter a tile production movement would itself reject.

local FieldPlayer = require("libs.hgss.src.field.FieldPlayer")

local FieldMovement = {}

local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local DIRECTIONS = { "east", "north", "south", "west" }

-- A resolved step still inside the resident physical-coverage region carries
-- its own `surfaceId`. One that crosses out of the resident region into a
-- cell the coverage window hasn't recentered onto yet carries none:
-- `FieldCoverage:project` (what `FieldPlayer:rebindCoverage` uses) can only
-- resolve a surface that is already part of the *current* resident region,
-- and recentering the region onto the new cell is a real, stateful step the
-- engine only performs from `FieldNavigationBoundary:afterCommittedMove`
-- after a real commit -- never from a disposable probe. So a nil surfaceId
-- here does not mean the step is invalid; it means this probe has reached
-- the edge of what it can safely evaluate without actually walking there.
-- Returns nil (never raises) so the search can route around/up-to the edge
-- instead of asserting on a destination production movement can reach fine.
---@param map table
---@param destination { surfaceId?: integer, fieldX: number, fieldZ: number, sourceCellKey?: integer, sourceSurfaceId?: integer }
---@return integer|nil
local function destinationSurfaceId(map, destination)
  if destination.surfaceId ~= nil then
    return destination.surfaceId
  end
  if not map.projectPhysicalPoint then
    return nil
  end
  local ok, point = pcall(
    map.projectPhysicalPoint,
    map,
    destination.fieldX,
    destination.fieldZ,
    destination.sourceCellKey,
    destination.sourceSurfaceId
  )
  if not ok or not point then
    return nil
  end
  return point.surfaceId
end

-- A step that lands in a cell already resident in the coverage window can
-- still cross into a different logical map (`FieldNavigationBoundary`'s own
-- `crossesLogicalZone` concept): the destination cell's own `mapHeaderId`
-- differs from the map the search started on. Committing that step rebinds
-- the player's surface identity onto the destination map's own composite
-- terrain (`FieldNavigationBoundary:afterCommittedMove`), so its real
-- surfaceId cannot be predicted from this search's fixed starting map the
-- way an ordinary in-zone step can -- it must be driven and observed like a
-- beyond-resident-region boundary crossing, never asserted against a planned
-- surfaceId.
local function crossesLogicalZone(map, destination)
  if not map.coverage then
    return false
  end
  local destinationHeader = map.coverage:mapHeaderAt(destination.fieldX, destination.fieldZ)
  return destinationHeader ~= nil and destinationHeader ~= map.mapId
end

local function isWarpTile(map, fieldX, fieldZ)
  for _, warp in ipairs(map.fieldData.events.warps) do
    if warp.x == fieldX and warp.z == fieldZ then
      return true
    end
  end
  return false
end

-- A coordinate event resolves the moment a step lands inside its rectangle
-- with its variable gate satisfied (`FieldEventResolver.resolveCoordinate`),
-- starting a foreground script that owns player input until it closes -- the
-- same "cannot pass through" contract a warp has, since a planned route
-- driving straight through it would silently stall waiting for a script the
-- route never accounted for. Only enterable as the final target, matching
-- the warp-avoidance contract above. An event whose gate is not currently
-- satisfied never resolves in production either, so it is not an obstacle.
local function isCoordinateEventTile(map, eventState, fieldX, fieldZ)
  for _, event in ipairs(map.fieldData.events.coordinates) do
    if
      fieldX >= event.x
      and fieldX < event.x + event.width
      and fieldZ >= event.z
      and fieldZ < event.z + event.height
      and eventState:getVar(event.variableId) == event.requiredValue
    then
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

local function stateKey(fieldX, fieldZ, surfaceId)
  return fieldX .. ":" .. fieldZ .. ":" .. tostring(surfaceId)
end

local function targetMatches(node, target)
  if node.fieldX ~= target.fieldX or node.fieldZ ~= target.fieldZ then
    return false
  end
  if target.surfaceId ~= nil then
    return node.surfaceId == target.surfaceId
  end
  return true
end

local function estimateRemaining(node, target)
  return math.abs(node.fieldX - target.fieldX) + math.abs(node.fieldZ - target.fieldZ)
end

-- Binary min-heap ordered by (f, h, insertion sequence), so a tie on total
-- estimated cost still breaks toward the node closer to the target and,
-- failing that, toward whichever was queued first (a stable, reproducible
-- route independent of table iteration order).
local function before(first, second)
  if first.f ~= second.f then
    return first.f < second.f
  end
  if first.h ~= second.h then
    return first.h < second.h
  end
  return first.sequence < second.sequence
end

local function push(open, node)
  open[#open + 1] = node
  local index = #open
  while index > 1 do
    local parent = math.floor(index / 2)
    if before(open[parent], open[index]) then
      break
    end
    open[parent], open[index] = open[index], open[parent]
    index = parent
  end
end

local function pop(open)
  local result = open[1]
  local last = table.remove(open)
  if #open > 0 then
    open[1] = last
    local index = 1
    while true do
      local left, right = index * 2, index * 2 + 1
      local smallest = index
      if left <= #open and before(open[left], open[smallest]) then
        smallest = left
      end
      if right <= #open and before(open[right], open[smallest]) then
        smallest = right
      end
      if smallest == index then
        break
      end
      open[index], open[smallest] = open[smallest], open[index]
      index = smallest
    end
  end
  return result
end

-- Plan a route to `target` using the exact production step-resolution rule
-- (`FieldPlayer:resolveStep`): map collision, terrain/surface crossing, and
-- live actor occupancy. Live actors are assumed stationary for the duration
-- of the search (true unless the scenario itself drives a script mid-plan).
-- A warp tile or a coordinate-event tile is only enterable as the final
-- target, never as a pass-through: entering either starts something (a
-- transition, a foreground script) that owns the field for longer than one
-- step, which a route plotted straight through it never accounts for. A*, not
-- plain breadth-first, is load-bearing here beyond search speed: outdoor
-- maps stream a bounded physical-coverage window around the live player, and
-- an undirected flood fill routinely wanders past its edge into cells the
-- coverage system has no data for at all, long before it would ever reach a
-- nearby target. The Manhattan-distance heuristic keeps the frontier moving
-- toward `target`, so it only ever probes cells a real, direct walk would
-- also cross.
--
-- When `target` sits beyond the resident physical-coverage region (a
-- genuinely seamless outdoor crossing production movement handles one real
-- committed step at a time), the search cannot resolve or expand past the
-- region's edge -- only a real step, followed by the engine's own
-- `FieldNavigationBoundary:afterCommittedMove` recenter, can. In that case
-- this returns `nil, boundary` instead of a complete route: `boundary.route`
-- walks up to the edge and `boundary.direction` is the one further step
-- that crosses it; `FieldMovement.moveToward` drives both, then replans.
---@param game table an AcceptanceHarness game
---@param target { fieldX: integer, fieldZ: integer, surfaceId: integer? }
---@return { direction: string, fieldX: integer, fieldZ: integer, surfaceId: integer }[]|nil, { route: table[], direction: string }|nil
function FieldMovement.route(game, target)
  assert(type(target.fieldX) == "number" and target.fieldX % 1 == 0, "route target fieldX must be an integer")
  assert(type(target.fieldZ) == "number" and target.fieldZ % 1 == 0, "route target fieldZ must be an integer")
  if target.surfaceId ~= nil then
    assert(
      type(target.surfaceId) == "number" and target.surfaceId % 1 == 0,
      "route target surfaceId must be an integer"
    )
  end
  local player = assert(game.runtime.player, "acceptance movement requires a live player")
  local map = assert(player.currentMap, "acceptance movement map required")
  local eventState = assert(game.runtime.eventState, "acceptance movement requires live event state")
  local occupancy = player.occupancy

  local start = { fieldX = player.fieldX, fieldZ = player.fieldZ, surfaceId = player.surfaceId, route = {} }
  local sequence = 1
  ---@type table<string, integer>
  local bestCost = { [stateKey(start.fieldX, start.fieldZ, start.surfaceId)] = 0 }
  local open = {}
  push(open, {
    node = start,
    g = 0,
    h = estimateRemaining(start, target),
    f = estimateRemaining(start, target),
    sequence = sequence,
  })
  local boundary
  while #open > 0 do
    local entry = pop(open)
    local node = entry.node
    if targetMatches(node, target) then
      return node.route
    end
    local probe = probeAt(map, occupancy, node)
    for _, direction in ipairs(DIRECTIONS) do
      local destination = probe:resolveStep(direction)
      if destination then
        local surfaceId = destinationSurfaceId(map, destination)
        if surfaceId == nil or crossesLogicalZone(map, destination) then
          -- Beyond the resident region, or a same-region logical-zone
          -- crossing: neither is safely expandable as an ordinary node, but
          -- both are still a candidate real committed step if closest found.
          local h = estimateRemaining(destination, target)
          if boundary == nil or h < boundary.h then
            boundary = { route = node.route, direction = direction, h = h }
          end
        else
          local key = stateKey(destination.fieldX, destination.fieldZ, surfaceId)
          local destNode = { fieldX = destination.fieldX, fieldZ = destination.fieldZ, surfaceId = surfaceId }
          local cost = entry.g + 1
          if
            (bestCost[key] == nil or cost < bestCost[key])
            and (
              targetMatches(destNode, target)
              or (
                not isWarpTile(map, destination.fieldX, destination.fieldZ)
                and not isCoordinateEventTile(map, eventState, destination.fieldX, destination.fieldZ)
              )
            )
          then
            bestCost[key] = cost
            local nextRoute = {}
            for index, step in ipairs(node.route) do
              nextRoute[index] = step
            end
            nextRoute[#nextRoute + 1] = {
              direction = direction,
              fieldX = destination.fieldX,
              fieldZ = destination.fieldZ,
              surfaceId = surfaceId,
            }
            local nextNode = {
              fieldX = destination.fieldX,
              fieldZ = destination.fieldZ,
              surfaceId = surfaceId,
              route = nextRoute,
            }
            local h = estimateRemaining(nextNode, target)
            sequence = sequence + 1
            push(open, { node = nextNode, g = cost, h = h, f = cost + h, sequence = sequence })
          end
        end
      end
    end
  end
  return nil, boundary
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
    local beforeStep = game:snapshot()
    -- HGSS input turns in place before it walks whenever the pressed
    -- direction is not the player's current facing; settle that turn first
    -- so each literal direction always resolves to a real production step.
    if beforeStep.player.facing ~= direction then
      game:face(direction)
    end
    game:move(direction)
    snapshots[index] = game:advanceUntil("production route move " .. tostring(index), function(snapshot)
      if snapshot.mapId ~= beforeStep.mapId then
        return true
      end
      return snapshot.player.motion == "idle"
        and (snapshot.player.fieldX ~= beforeStep.player.fieldX or snapshot.player.fieldZ ~= beforeStep.player.fieldZ)
    end, 120)
  end
  return snapshots
end

return FieldMovement
