-- Settles physical coverage immediately after a committed player displacement.
-- Logical map ownership and later field policies remain outside this boundary.

local FieldNavigationBoundary = {}
FieldNavigationBoundary.__index = FieldNavigationBoundary

local DIRECTION_DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

function FieldNavigationBoundary.new(options)
  options = options or {}
  return setmetatable({ zoneController = options.zoneController }, FieldNavigationBoundary)
end

function FieldNavigationBoundary:crossesLogicalZone(runtimeMap, player, direction)
  local coverage = runtimeMap.coverage
  local delta = DIRECTION_DELTAS[direction]
  if not coverage or not delta or not self.zoneController then
    return false
  end
  local destinationHeader = coverage:mapHeaderAt(player.fieldX + delta.x, player.fieldZ + delta.z)
  return destinationHeader ~= nil and destinationHeader ~= self.zoneController.currentMap.mapId
end

function FieldNavigationBoundary:afterCommittedMove(runtimeMap, player, camera)
  local coverage = runtimeMap.coverage
  if not coverage then
    return nil
  end
  local targetX = math.floor(player.fieldX / 32)
  local targetZ = math.floor(player.fieldZ / 32)
  local sourceCellKey = player.committedSourceCellKey
  local sourceSurfaceId = player.committedSourceSurfaceId
  if coverage.anchorX == targetX and coverage.anchorZ == targetZ then
    if sourceCellKey and sourceSurfaceId then
      player:rebindCoverage(runtimeMap, 0, 0, sourceCellKey, sourceSurfaceId)
    end
    return self.zoneController and self.zoneController:afterCoverageCommit(coverage, player) or coverage:status()
  end
  local oldOriginX, oldOriginZ = runtimeMap.coordinateOrigin.x, runtimeMap.coordinateOrigin.z
  if not sourceCellKey then
    local plate = runtimeMap.terrain:plate(player.surfaceId)
    if plate then
      sourceCellKey, sourceSurfaceId = plate.cellKey, plate.sourceSurfaceId
    end
  end
  coverage:recenter(targetX, targetZ)
  runtimeMap.fieldRegion = coverage.region
  runtimeMap.collision = coverage.region.collision
  runtimeMap.terrain = coverage.region.terrain
  runtimeMap.terrainDependencyHash = coverage.terrainDependencyHash
  runtimeMap.coordinateOrigin = { x = coverage.origin.x, z = coverage.origin.z }
  runtimeMap.physicalOrigin = coverage.origin
  local deltaX, deltaZ = oldOriginX - runtimeMap.coordinateOrigin.x, oldOriginZ - runtimeMap.coordinateOrigin.z
  player:rebindCoverage(runtimeMap, deltaX, deltaZ, sourceCellKey, sourceSurfaceId)
  camera:rebase(deltaX, deltaZ)
  local zoneChange
  if self.zoneController then
    zoneChange = self.zoneController:afterCoverageCommit(coverage, player)
  end
  return zoneChange or coverage:status()
end

return FieldNavigationBoundary
