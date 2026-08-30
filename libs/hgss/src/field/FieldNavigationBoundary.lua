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
  return setmetatable({
    zoneController = options.zoneController,
    residencyCoordinator = options.residencyCoordinator,
    coverageProvider = options.coverageProvider,
    reconcilePhysicalWorld = options.reconcilePhysicalWorld,
  }, FieldNavigationBoundary)
end

local function coverageFor(self, runtimeMap)
  if runtimeMap.coverage then
    return runtimeMap.coverage
  end
  if runtimeMap.scene and runtimeMap.scene.type == "outdoor" then
    return self.coverageProvider and self.coverageProvider() or nil
  end
  return nil
end

function FieldNavigationBoundary:crossesLogicalZone(runtimeMap, player, direction)
  local coverage = coverageFor(self, runtimeMap)
  local delta = DIRECTION_DELTAS[direction]
  if not coverage or not delta or not self.zoneController then
    return false
  end
  local destinationHeader = coverage:mapHeaderAt(player.fieldX + delta.x, player.fieldZ + delta.z)
  return destinationHeader ~= nil and destinationHeader ~= self.zoneController.currentMap.mapId
end

function FieldNavigationBoundary:afterCommittedMove(runtimeMap, player, camera)
  local coverage = coverageFor(self, runtimeMap)
  if not coverage then
    return nil
  end
  local targetX = math.floor(player.fieldX / 32)
  local targetZ = math.floor(player.fieldZ / 32)
  local sourceCellKey = player.committedSourceCellKey
  local sourceSurfaceId = player.committedSourceSurfaceId
  if sourceCellKey == nil or sourceSurfaceId == nil then
    local plate = assert(runtimeMap.terrain:plate(player.surfaceId), "player surface is missing after movement")
    sourceCellKey = assert(plate.cellKey, "player stable source cell identity is missing")
    sourceSurfaceId =
      assert(plate.sourceSurfaceId ~= nil and plate.sourceSurfaceId, "player stable source id is missing")
  end
  if coverage.anchorX == targetX and coverage.anchorZ == targetZ then
    player:rebindCoverage(runtimeMap, 0, 0, 0, sourceCellKey, sourceSurfaceId)
    if self.residencyCoordinator then
      return self.residencyCoordinator:afterCommittedMove(player)
    end
    return self.zoneController and self.zoneController:afterCoverageCommit(coverage, player) or coverage:status()
  end
  local currentOrigin = runtimeMap.physicalOrigin or coverage.origin
  local oldOrigin = {
    x = currentOrigin.x,
    y = currentOrigin.y,
    z = currentOrigin.z,
  }
  local function syncPhysicalCommit()
    if runtimeMap.syncPhysicalFields then
      runtimeMap:syncPhysicalFields()
    else
      runtimeMap.fieldRegion = coverage.region
      runtimeMap.collision = coverage.region.collision
      runtimeMap.terrain = coverage.region.terrain
      runtimeMap.terrainDependencyHash = coverage.terrainDependencyHash
      runtimeMap.coordinateOrigin = { x = coverage.origin.x, z = coverage.origin.z }
      runtimeMap.physicalOrigin = coverage.origin
    end
    local newOrigin = assert(runtimeMap.physicalOrigin)
    local deltaX = oldOrigin.x - newOrigin.x
    local deltaY = oldOrigin.y - newOrigin.y
    local deltaZ = oldOrigin.z - newOrigin.z
    player:rebindCoverage(runtimeMap, deltaX, deltaY, deltaZ, sourceCellKey, sourceSurfaceId)
    camera:rebase(deltaX, deltaY, deltaZ)
  end
  if self.residencyCoordinator then
    return self.residencyCoordinator:afterCommittedMove(player, {
      targetX = targetX,
      targetZ = targetZ,
      onPhysicalCommit = syncPhysicalCommit,
    })
  end
  coverage:recenter(targetX, targetZ)
  syncPhysicalCommit()
  if self.reconcilePhysicalWorld then
    self.reconcilePhysicalWorld()
  end
  local zoneChange
  if self.zoneController then
    zoneChange = self.zoneController:afterCoverageCommit(coverage, player)
  end
  return zoneChange or coverage:status()
end

return FieldNavigationBoundary
