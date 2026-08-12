-- Deterministic field actor movement over permission and BDHC terrain data.
-- Integer field coordinates commit only after a fixed-duration tile step;
-- continuous XYZ is the shared camera and renderer position throughout it.
--
-- Collision order: collision, then terrain surface
-- transition, then dynamic occupancy. The occupancy check is injected as a
-- pure predicate -- `occupancy(fieldX, fieldZ, surfaceId) -> blockingActorId or
-- nil` -- so the player never knows which object blocks it, and the actor
-- manager stays the only owner of the occupancy index.

local Errors = require("libs.errors.src.Errors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")

---@class FieldPlayer
---@field currentMap RuntimeFieldMap
---@field resolver SurfaceResolver
---@field occupancy fun(fieldX: integer, fieldZ: integer, surfaceId: integer): string|nil?
---@field fieldX integer
---@field fieldZ integer
---@field localX integer
---@field localZ integer
---@field worldX number
---@field worldY number
---@field worldZ number
---@field previousWorldX number
---@field previousWorldY number
---@field previousWorldZ number
---@field surfaceId integer
---@field facing FieldDirection
---@field motion "idle"|"walking"
---@field progressTicks integer
---@field durationTicks integer
---@field bufferedDirection FieldDirection?
---@field from table?
---@field to table?
local FieldPlayer = {}
FieldPlayer.__index = FieldPlayer

-- Provisional gameplay timing, centralized for later emulator calibration.
FieldPlayer.WALK_STEP_TICKS = 8

---@alias FieldDirection "north"|"south"|"west"|"east"

---@class FieldPlayerOptions
---@field currentMap RuntimeFieldMap
---@field fieldX integer
---@field fieldZ integer
---@field surfaceId integer
---@field facing FieldDirection?
---@field occupancy? fun(fieldX: integer, fieldZ: integer, surfaceId: integer): string|nil

local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local function isInteger(value)
  return type(value) == "number" and value == math.floor(value)
end

-- Only failures that genuinely mean the step was legally rejected are
-- ordinary blocked moves: the destination outside permission coverage, or
-- its terrain beyond the reachable step height. Malformed or ambiguous
-- terrain, and a current surface inconsistent with the player's own position,
-- are corrupted state and propagate instead.
local function recoverableMovementError(err)
  return Errors.is(err) and (err.code == "FIELD_COORDINATES_OUT_OF_COVERAGE" or SurfaceResolver.isStepRejection(err))
end

---@param options FieldPlayerOptions
---@return FieldPlayer
function FieldPlayer.new(options)
  assert(type(options) == "table" and options.currentMap, "FieldPlayer map required")
  assert(isInteger(options.fieldX) and isInteger(options.fieldZ), "FieldPlayer integer field coordinates required")
  assert(type(options.surfaceId) == "number", "FieldPlayer surface id required")
  assert(
    options.occupancy == nil or type(options.occupancy) == "function",
    "FieldPlayer occupancy predicate must be a function"
  )
  local map = options.currentMap
  local localX, localZ = FieldCoordinates.fieldToLocal(map, options.fieldX, options.fieldZ)
  local sample = map.terrain:sample(
    options.surfaceId,
    localX + FieldCoordinates.TILE_CENTER_OFFSET,
    localZ + FieldCoordinates.TILE_CENTER_OFFSET
  )
  local point = FieldCoordinates.fieldToWorld(map, options.fieldX, options.fieldZ, sample.worldY)
  return setmetatable({
    currentMap = map,
    resolver = SurfaceResolver.new(map.terrain),
    occupancy = options.occupancy,
    fieldX = options.fieldX,
    fieldZ = options.fieldZ,
    localX = localX,
    localZ = localZ,
    worldX = point.x,
    worldY = point.y,
    worldZ = point.z,
    previousWorldX = point.x,
    previousWorldY = point.y,
    previousWorldZ = point.z,
    surfaceId = sample.surfaceId,
    facing = options.facing or "south",
    motion = "idle",
    progressTicks = 0,
    durationTicks = FieldPlayer.WALK_STEP_TICKS,
  }, FieldPlayer)
end

function FieldPlayer:_resolveStep(direction)
  local delta = assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  local destinationX, destinationZ = self.fieldX + delta.x, self.fieldZ + delta.z
  local ok, result = pcall(function()
    local destinationLocalX, destinationLocalZ =
      FieldCoordinates.fieldToLocal(self.currentMap, destinationX, destinationZ)
    if self.currentMap.collision:isBlockedLocal(destinationLocalX, destinationLocalZ) then
      return nil
    end
    local sourceX, sourceZ =
      self.localX + FieldCoordinates.TILE_CENTER_OFFSET, self.localZ + FieldCoordinates.TILE_CENTER_OFFSET
    local destinationCenterX, destinationCenterZ =
      destinationLocalX + FieldCoordinates.TILE_CENTER_OFFSET, destinationLocalZ + FieldCoordinates.TILE_CENTER_OFFSET
    local sample = self.resolver:resolve({
      localX = destinationCenterX,
      localZ = destinationCenterZ,
      currentSurfaceId = self.surfaceId,
      currentY = self.worldY,
      crossing = {
        fromX = sourceX,
        fromZ = sourceZ,
        toX = destinationCenterX,
        toZ = destinationCenterZ,
      },
    })
    local point = FieldCoordinates.fieldToWorld(self.currentMap, destinationX, destinationZ, sample.worldY)
    -- Occupancy is checked against the resolved destination surface, so an
    -- actor on a different surface never blocks a same-cell approach, and it
    -- runs only after terrain accepts the step.
    if self.occupancy then
      if self.occupancy(destinationX, destinationZ, sample.surfaceId) then
        return nil
      end
    end
    return {
      fieldX = destinationX,
      fieldZ = destinationZ,
      localX = destinationLocalX,
      localZ = destinationLocalZ,
      worldX = point.x,
      worldY = point.y,
      worldZ = point.z,
      surfaceId = sample.surfaceId,
    }
  end)
  if not ok then
    if recoverableMovementError(result) then
      return nil
    end
    error(result)
  end
  return result
end

function FieldPlayer:tryStep(direction)
  assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  assert(self.motion == "idle", "cannot begin a field step while walking")
  self.facing = direction
  local destination = self:_resolveStep(direction)
  if not destination then
    return false
  end
  self.from = {
    fieldX = self.fieldX,
    fieldZ = self.fieldZ,
    localX = self.localX,
    localZ = self.localZ,
    worldX = self.worldX,
    worldY = self.worldY,
    worldZ = self.worldZ,
    surfaceId = self.surfaceId,
  }
  self.to = destination
  self.motion = "walking"
  self.progressTicks = 0
  return true
end

function FieldPlayer:_advanceStep()
  assert(self.motion == "walking" and self.from and self.to, "walking step endpoints required")
  self.progressTicks = self.progressTicks + 1
  local progress = self.progressTicks / self.durationTicks
  self.worldX = self.from.worldX + (self.to.worldX - self.from.worldX) * progress
  self.worldZ = self.from.worldZ + (self.to.worldZ - self.from.worldZ) * progress
  if self.from.surfaceId == self.to.surfaceId then
    local localX = self.from.localX
      + FieldCoordinates.TILE_CENTER_OFFSET
      + (self.to.localX - self.from.localX) * progress
    local localZ = self.from.localZ
      + FieldCoordinates.TILE_CENTER_OFFSET
      + (self.to.localZ - self.from.localZ) * progress
    self.worldY = self.currentMap.terrain:sampleHeight(self.to.surfaceId, localX, localZ)
  else
    self.worldY = self.from.worldY + (self.to.worldY - self.from.worldY) * progress
  end
  if self.progressTicks < self.durationTicks then
    return false
  end

  self.fieldX, self.fieldZ = self.to.fieldX, self.to.fieldZ
  self.localX, self.localZ = self.to.localX, self.to.localZ
  self.worldX, self.worldY, self.worldZ = self.to.worldX, self.to.worldY, self.to.worldZ
  self.surfaceId = self.to.surfaceId
  self.motion = "idle"
  self.progressTicks = 0
  self.from, self.to = nil, nil
  return true
end

function FieldPlayer:updateFixed(input)
  input = input or {}
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = self.worldX, self.worldY, self.worldZ

  if self.motion == "walking" then
    if input.pressedDirection then
      self.bufferedDirection = input.pressedDirection
    end
    return self:_advanceStep()
  end

  local direction
  if self.bufferedDirection and self.bufferedDirection == input.heldDirection then
    direction = self.bufferedDirection
  else
    self.bufferedDirection = nil
    direction = input.pressedDirection or input.heldDirection
  end
  if not direction then
    return false
  end
  self.bufferedDirection = nil
  if self:tryStep(direction) then
    self:_advanceStep()
  end
  return false
end

function FieldPlayer:renderPosition(alpha)
  alpha = alpha == nil and 1 or math.max(0, math.min(1, alpha))
  return {
    x = self.previousWorldX + (self.worldX - self.previousWorldX) * alpha,
    y = self.previousWorldY + (self.worldY - self.previousWorldY) * alpha,
    z = self.previousWorldZ + (self.worldZ - self.previousWorldZ) * alpha,
  }
end

function FieldPlayer:status()
  local plate = assert(self.currentMap.terrain:plate(self.surfaceId), "player surface missing")
  return {
    fieldX = self.fieldX,
    fieldZ = self.fieldZ,
    localX = self.localX,
    localZ = self.localZ,
    worldY = self.worldY,
    surfaceId = self.surfaceId,
    surfaceNormal = { x = plate.normal.x, y = plate.normal.y, z = plate.normal.z },
    slopeClass = plate.slopeClass,
    destinationSurfaceId = self.to and self.to.surfaceId or nil,
    facing = self.facing,
    motion = self.motion,
  }
end

return FieldPlayer
