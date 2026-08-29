-- Discovers deterministic navigation targets from the generated physical-cell
-- cache and normalized field events. The scan order is numeric and the
-- returned routes are shortest paths with stable direction tie-breaking.

local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local FieldCellCache = require("libs.assets.src.FieldCellCache")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldTraversal = require("libs.engine.src.FieldTraversal")
local MapResolver = require("romdump.src.digest.MapResolver")
local MapCatalog = require("romdump.src.digest.MapCatalog")

local NavigationFacts = {}

local DIRECTIONS = {
  { name = "north", x = 0, z = -1 },
  { name = "south", x = 0, z = 1 },
  { name = "west", x = -1, z = 0 },
  { name = "east", x = 1, z = 0 },
}

-- HGSS's fixed metatile behavior values. This table is deliberately local to
-- fact discovery: production traversal remains the system under test.
local SOURCE_LEDGE_DIRECTIONS = {
  [56] = "east",
  [57] = "west",
  [58] = "north",
  [59] = "south",
}

local function key(fieldX, fieldZ)
  return fieldX .. ":" .. fieldZ
end

local function sortedMatrices(index)
  local matrices = {}
  for _, matrix in ipairs(index.matrices) do
    matrices[#matrices + 1] = matrix
  end
  table.sort(matrices, function(a, b)
    return a.matrixMemberId < b.matrixMemberId
  end)
  return matrices
end

local function sortedCells(matrix)
  local cells = {}
  for _, cell in ipairs(matrix.cells) do
    cells[#cells + 1] = cell
  end
  table.sort(cells, function(a, b)
    return a.index < b.index
  end)
  return cells
end

local function loadGrid(cacheFs, cell)
  local record = assert(cacheFs:loadLua(cell.file))
  local bytes = assert(cacheFs:read(record.collision.file))
  return assert(CollisionGridAsset.decode(bytes)), record
end

local function buildWorld(cacheFs, index)
  local cells = {}
  local matrices = {}
  for _, matrix in ipairs(sortedMatrices(index)) do
    matrices[matrix.matrixMemberId] = matrix
    for _, cell in ipairs(sortedCells(matrix)) do
      local grid, record = loadGrid(cacheFs, cell)
      cells[cell.matrixMemberId .. ":" .. cell.x .. ":" .. cell.z] = {
        descriptor = cell,
        record = record,
        grid = grid,
      }
    end
  end
  return cells, matrices
end

local function cellAt(cells, fieldX, fieldZ)
  local cellX, cellZ = math.floor(fieldX / 32), math.floor(fieldZ / 32)
  local keys = {}
  for cellKey in pairs(cells) do
    keys[#keys + 1] = cellKey
  end
  table.sort(keys)
  for _, cellKey in ipairs(keys) do
    local cell = cells[cellKey]
    if cell.descriptor.x == cellX and cell.descriptor.z == cellZ then
      return cell
    end
  end
  return nil
end

local function tileAt(cells, fieldX, fieldZ)
  local cell = cellAt(cells, fieldX, fieldZ)
  if not cell then
    return nil
  end
  local localX, localZ = fieldX % 32, fieldZ % 32
  return cell.grid.cells[localZ * 32 + localX + 1], cell
end

local function bfs(cells, startX, startZ)
  local queue = { { fieldX = startX, fieldZ = startZ, route = {} } }
  local seen = { [key(startX, startZ)] = true }
  local head = 1
  local nodes = {}
  while queue[head] do
    local node = queue[head]
    head = head + 1
    nodes[#nodes + 1] = node
    for _, direction in ipairs(DIRECTIONS) do
      local nextX, nextZ = node.fieldX + direction.x, node.fieldZ + direction.z
      local destination = tileAt(cells, nextX, nextZ)
      if destination then
        local decision = FieldTraversal.classify(destination, direction.name)
        local landingX, landingZ = nextX, nextZ
        if decision.kind == "ledge_jump" then
          landingX, landingZ = node.fieldX + direction.x * 2, node.fieldZ + direction.z * 2
          destination = tileAt(cells, landingX, landingZ)
          if not destination or destination.blocked then
            destination = nil
          end
        end
        if destination and decision.kind ~= "blocked" and decision.kind ~= "field_action" then
          local destinationKey = key(landingX, landingZ)
          if not seen[destinationKey] then
            seen[destinationKey] = true
            local route = {}
            for index, step in ipairs(node.route) do
              route[index] = step
            end
            route[#route + 1] = direction.name
            queue[#queue + 1] = { fieldX = landingX, fieldZ = landingZ, route = route, previous = node }
          end
        end
      end
    end
  end
  return nodes
end

local function firstNode(nodes, predicate)
  for _, node in ipairs(nodes) do
    local tile, cell = tileAt(nodes.cells, node.fieldX, node.fieldZ)
    if tile and predicate(tile, cell) then
      return node, tile, cell
    end
  end
  return nil
end

---@param cacheFs table
---@param romFs table
---@return table
function NavigationFacts.discover(cacheFs, romFs)
  local index = FieldCellCache.loadIndex(cacheFs)
  local cells = buildWorld(cacheFs, index)
  local newBark = assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
  local route29 = assert(MapResolver.resolve(romFs, "MAP_ROUTE_29"))
  local startX, startZ = newBark.worldOriginX + 12, newBark.worldOriginZ + 10
  local nodes = bfs(cells, startX, startZ)
  nodes.cells = cells

  local zoneBoundary
  for _, node in ipairs(nodes) do
    for _, direction in ipairs(DIRECTIONS) do
      local tile, cell = tileAt(cells, node.fieldX + direction.x, node.fieldZ + direction.z)
      if cell and cell.descriptor.mapHeaderId == route29.map.id and tile and not tile.blocked then
        zoneBoundary = {
          fieldX = node.fieldX + direction.x,
          fieldZ = node.fieldZ + direction.z,
          approach = { fieldX = node.fieldX, fieldZ = node.fieldZ },
          direction = direction.name,
        }
        break
      end
    end
    if zoneBoundary then
      break
    end
  end
  assert(zoneBoundary, "New Bark has no reachable Route 29 boundary")

  local water
  local newBarkId = MapCatalog.require("MAP_NEW_BARK").id
  for _, node in ipairs(nodes) do
    for _, direction in ipairs(DIRECTIONS) do
      local tile, cell = tileAt(cells, node.fieldX + direction.x, node.fieldZ + direction.z)
      if
        cell
        and cell.descriptor.mapHeaderId == newBarkId
        and tile
        and (tile.behavior == 16 or tile.behavior == 21)
      then
        water = {
          fieldX = node.fieldX + direction.x,
          fieldZ = node.fieldZ + direction.z,
          approach = { fieldX = node.fieldX, fieldZ = node.fieldZ },
          direction = direction.name,
        }
        break
      end
    end
    if water then
      break
    end
  end
  assert(water, "New Bark has no reachable on-foot water target")

  local grass = assert(
    firstNode(nodes, function(tile, cell)
      return cell.descriptor.mapHeaderId == route29.map.id and (tile.behavior == 2 or tile.behavior == 3)
    end),
    "Route 29 has no reachable grass target"
  )

  local ledgeApproach
  for _, node in ipairs(nodes) do
    for _, direction in ipairs(DIRECTIONS) do
      local tile, cell = tileAt(cells, node.fieldX + direction.x, node.fieldZ + direction.z)
      if cell and cell.descriptor.mapHeaderId == route29.map.id and tile then
        if SOURCE_LEDGE_DIRECTIONS[tile.behavior] == direction.name then
          local landingTile = tileAt(cells, node.fieldX + direction.x * 2, node.fieldZ + direction.z * 2)
          if landingTile and not landingTile.blocked then
            ledgeApproach = {
              fieldX = node.fieldX,
              fieldZ = node.fieldZ,
              direction = direction.name,
              landing = { fieldX = node.fieldX + direction.x * 2, fieldZ = node.fieldZ + direction.z * 2 },
              route = node.route,
            }
            break
          end
        end
      end
    end
    if ledgeApproach then
      break
    end
  end
  assert(ledgeApproach, "Route 29 has no reachable directional ledge")

  local far
  for _, node in ipairs(nodes) do
    local cell = cellAt(cells, node.fieldX, node.fieldZ)
    if
      cell
      and cell.descriptor.mapHeaderId == route29.map.id
      and (math.abs(cell.descriptor.x - newBark.matrixX) >= 2 or math.abs(cell.descriptor.z - newBark.matrixZ) >= 2)
    then
      far = node
      break
    end
  end
  assert(far, "no reachable Route 29 cell outside the original neighborhood")

  local field = assert(cacheFs:loadLua(FieldMapDataCache.fieldPath(newBark.map.id)))
  local buildingWarp
  for _, warp in ipairs(field.events.warps) do
    if warp.destinationMapId ~= newBark.map.id then
      for _, node in ipairs(nodes) do
        for _, direction in ipairs(DIRECTIONS) do
          if node.fieldX + direction.x == warp.x and node.fieldZ + direction.z == warp.z then
            buildingWarp = {
              fieldX = node.fieldX,
              fieldZ = node.fieldZ,
              direction = direction.name,
              destinationMapId = warp.destinationMapId,
              destinationWarpId = warp.destinationWarpId,
            }
            break
          end
        end
        if buildingWarp then
          break
        end
      end
    end
    if buildingWarp then
      break
    end
  end
  assert(buildingWarp, "New Bark has no deterministic reachable building warp")

  return {
    newBark = {
      mapId = newBark.map.id,
      matrixX = newBark.matrixX,
      matrixZ = newBark.matrixZ,
      fieldX = startX,
      fieldZ = startZ,
    },
    route29 = { mapId = route29.map.id, matrixX = route29.matrixX, matrixZ = route29.matrixZ },
    zoneBoundary = zoneBoundary,
    water = water,
    grass = { fieldX = grass.fieldX, fieldZ = grass.fieldZ, route = grass.route },
    ledge = ledgeApproach,
    far = { fieldX = far.fieldX, fieldZ = far.fieldZ, route = far.route },
    buildingWarp = buildingWarp,
  }
end

return NavigationFacts
