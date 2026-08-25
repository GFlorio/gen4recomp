-- Settles physical coverage immediately after a committed player displacement.
-- Logical map ownership and later field policies remain outside this boundary.

local FieldNavigationBoundary = {}
FieldNavigationBoundary.__index = FieldNavigationBoundary

function FieldNavigationBoundary.new()
  return setmetatable({}, FieldNavigationBoundary)
end

function FieldNavigationBoundary:afterCommittedMove(runtimeMap, player, camera)
  local coverage = runtimeMap.coverage
  if not coverage then
    return nil
  end
  local targetX = math.floor(player.fieldX / 32)
  local targetZ = math.floor(player.fieldZ / 32)
  if coverage.anchorX == targetX and coverage.anchorZ == targetZ then
    return coverage:status()
  end
  local oldOriginX, oldOriginZ = runtimeMap.coordinateOrigin.x, runtimeMap.coordinateOrigin.z
  local sourceCellKey, sourceSurfaceId
  local plate = runtimeMap.terrain:plate(player.surfaceId)
  if plate then
    sourceCellKey, sourceSurfaceId = plate.cellKey, plate.sourceSurfaceId
  end
  coverage:recenter(targetX, targetZ)
  runtimeMap.fieldRegion = coverage.region
  runtimeMap.collision = coverage.region.collision
  runtimeMap.terrain = coverage.region.terrain
  runtimeMap.terrainDependencyHash = coverage.terrainDependencyHash
  runtimeMap.coordinateOrigin = { x = targetX * 32, z = targetZ * 32 }
  local deltaX, deltaZ = oldOriginX - runtimeMap.coordinateOrigin.x, oldOriginZ - runtimeMap.coordinateOrigin.z
  player:rebindCoverage(runtimeMap, deltaX, deltaZ, sourceCellKey, sourceSurfaceId)
  camera:rebase(deltaX, deltaZ)
  return coverage:status()
end

return FieldNavigationBoundary
