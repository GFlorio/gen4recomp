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
local FieldTraversal = require("libs.engine.src.FieldTraversal")

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
---@field motion "idle"|"walking"|"turning"|"jumping"|"transition"
---@field progressTicks integer
---@field durationTicks integer
---@field animationPaused boolean
---@field bufferedDirection FieldDirection?
---@field bufferedDirectionFresh boolean
---@field from table?
---@field to table?
---@field committedSourceCellKey string?
---@field committedSourceSurfaceId integer?
---@field transitionKind "ladder_exit"|"ladder_down_exit"|"vertical_return"|"held_stair"|nil
---@field transitionFacing FieldDirection?
---@field transitionFrom table?
---@field transitionTo table?
---@field transitionProgress number?
local FieldPlayer = {}
FieldPlayer.__index = FieldPlayer

-- Gameplay timing constants, centralized so emulator calibration changes
-- exactly one place.
FieldPlayer.WALK_STEP_TICKS = 8
FieldPlayer.TURN_TICKS = 2
FieldPlayer.LEDGE_JUMP_TICKS = 16

---@alias FieldDirection "north"|"south"|"west"|"east"

---@class FieldPlayerOptions
---@field currentMap RuntimeFieldMap
---@field fieldX integer
---@field fieldZ integer
---@field surfaceId integer
---@field facing FieldDirection?
---@field initialWorldY number?
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

local function projectPoint(runtimeMap, fieldX, fieldZ, cellKey, sourceSurfaceId)
  if runtimeMap.projectPhysicalPoint then
    return runtimeMap:projectPhysicalPoint(fieldX, fieldZ, cellKey, sourceSurfaceId)
  end
  local region = assert(runtimeMap.fieldRegion, "physical field region required")
  local surfaceId = assert(region:sourceSurface(cellKey, sourceSurfaceId), "player surface is absent from coverage")
  local origin = assert(runtimeMap.physicalOrigin or {
    x = runtimeMap.coordinateOrigin.x,
    y = 0,
    z = runtimeMap.coordinateOrigin.z,
  })
  local localX, localZ = fieldX - origin.x, fieldZ - origin.z
  local centerX, centerZ = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    cellKey = cellKey,
    sourceSurfaceId = sourceSurfaceId,
    surfaceId = surfaceId,
    localX = localX,
    localZ = localZ,
    worldX = centerX,
    worldY = runtimeMap.terrain:sampleHeight(surfaceId, centerX, centerZ),
    worldZ = centerZ,
  }
end

-- Only failures that genuinely mean the step was legally rejected are
-- ordinary blocked moves: the destination outside permission coverage, or
-- its terrain beyond the reachable step height. Malformed or ambiguous
-- terrain, and a current surface inconsistent with the player's own position,
-- are corrupted state and propagate instead.
local function recoverableMovementError(err)
  if not Errors.is(err) then
    return false
  end
  local errorObject = err --[[@as Errors.Error]]
  return errorObject.code == "FIELD_COORDINATES_OUT_OF_COVERAGE" or SurfaceResolver.isStepRejection(errorObject)
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
  local sample = options.initialWorldY == nil
      and map.terrain:sample(
        options.surfaceId,
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
    or { surfaceId = options.surfaceId, worldY = options.initialWorldY }
  local point = FieldCoordinates.fieldToWorld(map, options.fieldX, options.fieldZ, sample.worldY)
  local plate = map.terrain:plate(sample.surfaceId)
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
    committedSourceCellKey = plate and plate.cellKey or nil,
    committedSourceSurfaceId = plate and plate.sourceSurfaceId or nil,
    facing = options.facing or "south",
    motion = "idle",
    progressTicks = 0,
    durationTicks = FieldPlayer.WALK_STEP_TICKS,
    animationPaused = false,
    transitionKind = nil,
    transitionFacing = nil,
    transitionProgress = nil,
    bufferedDirectionFresh = false,
  }, FieldPlayer)
end

-- Resolve the adjacent tile for a step: permission blocking and dynamic
-- occupancy gate ordinary steps; `bypassBlocking` skips both for the door
-- choreography's scripted steps (the player must walk into the door tile
-- normal movement cannot enter). Terrain surface resolution always governs.
function FieldPlayer:_resolveStep(direction, bypassBlocking)
  local delta = assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  local destinationX, destinationZ = self.fieldX + delta.x, self.fieldZ + delta.z
  local currentSurfaceCoversSource = self.currentMap.terrain:contains(
    self.surfaceId,
    self.localX + FieldCoordinates.TILE_CENTER_OFFSET,
    self.localZ + FieldCoordinates.TILE_CENTER_OFFSET
  )
  if
    not bypassBlocking
    and self.currentMap.coverage
    and (not self.currentMap.coverage:containsGlobal(destinationX, destinationZ) or not currentSurfaceCoversSource)
  then
    local probe = self.currentMap:probePhysicalCell(destinationX, destinationZ)
    if not probe or probe.collision.blocked then
      return nil
    end
    local localX = destinationX - self.currentMap.coordinateOrigin.x
    local localZ = destinationZ - self.currentMap.coordinateOrigin.z
    if self.occupancy and self.occupancy(destinationX, destinationZ, probe.sourceSurfaceId) then
      return nil
    end
    return {
      fieldX = destinationX,
      fieldZ = destinationZ,
      localX = localX,
      localZ = localZ,
      worldX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      worldY = probe.worldY,
      worldZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      surfaceId = self.surfaceId,
      sourceCellKey = probe.cellKey,
      sourceSurfaceId = probe.sourceSurfaceId,
    }
  end
  local ok, result = pcall(function()
    local destinationLocalX, destinationLocalZ =
      FieldCoordinates.fieldToLocal(self.currentMap, destinationX, destinationZ)
    if not bypassBlocking and self.currentMap.collision:isBlockedLocal(destinationLocalX, destinationLocalZ) then
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
    local plate = assert(self.currentMap.terrain:plate(sample.surfaceId), "resolved destination surface missing")
    -- Occupancy is checked against the resolved destination surface, so an
    -- actor on a different surface never blocks a same-cell approach, and it
    -- runs only after terrain accepts the step.
    if not bypassBlocking and self.occupancy then
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
      sourceCellKey = plate.cellKey,
      sourceSurfaceId = plate.sourceSurfaceId,
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

-- Shared step start for ordinary and scripted steps: capture the from state,
-- adopt the resolved destination, and enter the walking motion.
function FieldPlayer:_beginStep(direction, destination)
  self.facing = direction
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
  self.durationTicks = FieldPlayer.WALK_STEP_TICKS
end

function FieldPlayer:_beginTurn(direction)
  self.facing = direction
  self.motion = "turning"
  self.progressTicks = 0
  self.durationTicks = FieldPlayer.TURN_TICKS
end

function FieldPlayer:_beginJump(direction, destination)
  self.facing = direction
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
  self.motion = "jumping"
  self.progressTicks = 0
  self.durationTicks = FieldPlayer.LEDGE_JUMP_TICKS
end

function FieldPlayer:_advanceTurn()
  assert(self.motion == "turning", "turning motion required")
  self.progressTicks = self.progressTicks + 1
  if self.progressTicks >= FieldPlayer.TURN_TICKS then
    self.motion = "idle"
    self.progressTicks = 0
  end
  return false
end

function FieldPlayer:tryStep(direction)
  assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  assert(self.motion == "idle", "cannot begin a field step while walking")
  self.facing = direction

  local delta = DELTAS[direction]
  local destinationX, destinationZ = self.fieldX + delta.x, self.fieldZ + delta.z
  local ok, destinationCell = pcall(function()
    if
      self.currentMap.coverage
      and not self.currentMap.coverage:containsGlobal(destinationX, destinationZ)
      and self.currentMap.probePhysicalCell
    then
      local probe = self.currentMap:probePhysicalCell(destinationX, destinationZ)
      return probe and probe.collision or { blocked = true }
    end
    if not self.currentMap.collision.getLocal then
      local blocked = false
      if self.currentMap.collision.isBlockedLocal then
        blocked = self.currentMap.collision:isBlockedLocal(destinationX, destinationZ)
      end
      return { blocked = blocked }
    end
    local localX, localZ = FieldCoordinates.fieldToLocal(self.currentMap, destinationX, destinationZ)
    return self.currentMap.collision:getLocal(localX, localZ)
  end)
  if not ok then
    if recoverableMovementError(destinationCell) then
      return false
    end
    error(destinationCell)
  end

  local decision = FieldTraversal.classify(destinationCell, direction)
  if decision.kind == "field_action" or decision.kind == "blocked" then
    return false
  elseif decision.kind == "ledge_jump" then
    local destination = self:_resolveLedgeLanding(direction)
    if not destination then
      return false
    end
    self:_beginJump(direction, destination)
    return true
  end

  local destination = self:_resolveStep(direction)
  if not destination then
    return false
  end
  self:_beginStep(direction, destination)
  return true
end

function FieldPlayer:_resolveLedgeLanding(direction)
  local delta = assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  local landingX, landingZ = self.fieldX + delta.x * 2, self.fieldZ + delta.z * 2
  local ok, result = pcall(function()
    local landingLocalX, landingLocalZ = FieldCoordinates.fieldToLocal(self.currentMap, landingX, landingZ)
    if self.currentMap.collision:isBlockedLocal(landingLocalX, landingLocalZ) then
      return nil
    end
    local landingCenterX = landingLocalX + FieldCoordinates.TILE_CENTER_OFFSET
    local landingCenterZ = landingLocalZ + FieldCoordinates.TILE_CENTER_OFFSET
    local sample = self.resolver:resolve({
      localX = landingCenterX,
      localZ = landingCenterZ,
      currentSurfaceId = self.surfaceId,
      currentY = self.worldY,
    })
    if self.occupancy and self.occupancy(landingX, landingZ, sample.surfaceId) then
      return nil
    end
    local point = FieldCoordinates.fieldToWorld(self.currentMap, landingX, landingZ, sample.worldY)
    local plate = assert(self.currentMap.terrain:plate(sample.surfaceId), "resolved landing surface missing")
    return {
      fieldX = landingX,
      fieldZ = landingZ,
      localX = landingLocalX,
      localZ = landingLocalZ,
      worldX = point.x,
      worldY = sample.worldY,
      worldZ = point.z,
      surfaceId = sample.surfaceId,
      sourceCellKey = plate.cellKey,
      sourceSurfaceId = plate.sourceSurfaceId,
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

-- A scripted step for the door choreography: like tryStep, but the blocked
-- permission check and dynamic occupancy are bypassed, so the player can walk
-- into the door tile normal movement cannot enter and out of a door tile onto
-- the floor beyond it. Terrain surface resolution still governs (a door tile
-- without a walkable surface simply fails, and the choreography continues by
-- fading). Returns true when the step began.
function FieldPlayer:scriptedStep(direction)
  assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  assert(self.motion == "idle", "cannot begin a scripted step while walking")
  local destination = self:_resolveStep(direction, true)
  if not destination then
    return false
  end
  self:_beginStep(direction, destination)
  return true
end

function FieldPlayer:beginTransitionStep(direction)
  assert(self.motion == "idle", "cannot begin a transition step while moving")
  return self:scriptedStep(direction)
end

-- Starts destination-side horizontal-stair presentation from an adjacent
-- sampled point into the player's existing logical anchor. This is visual
-- motion only: the player keeps the destination warp's logical ownership.
function FieldPlayer:beginTransitionHeldStair(startWorld, facing)
  assert(self.motion == "idle", "cannot begin held-stair presentation while moving")
  assert(facing == "east" or facing == "west", "held-stair presentation facing required")
  assert(type(startWorld) == "table", "held-stair presentation start required")
  assert(type(startWorld.x) == "number" and type(startWorld.y) == "number" and type(startWorld.z) == "number")
  local anchor = { x = self.worldX, y = self.worldY, z = self.worldZ }
  self.motion = "transition"
  self.facing = facing
  self.progressTicks = 0
  self.durationTicks = FieldPlayer.WALK_STEP_TICKS
  self.transitionKind = "held_stair"
  self.transitionFacing = facing
  self.transitionProgress = 0
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = startWorld.x, startWorld.y, startWorld.z
  self.worldX, self.worldY, self.worldZ = startWorld.x, startWorld.y, startWorld.z
  self.transitionFrom = { x = startWorld.x, y = startWorld.y, z = startWorld.z }
  self.transitionTo = anchor
  return true
end

function FieldPlayer:pauseTransitionAnimation()
  self.animationPaused = true
end

function FieldPlayer:resumeTransitionAnimation()
  self.animationPaused = false
end

local function beginTransitionPresentation(self, kind, facing, target)
  assert(self.motion == "idle", "cannot begin a transition motion while moving")
  self.motion = "transition"
  self.facing = facing
  self.progressTicks = 0
  self.durationTicks = 16
  self.transitionKind = kind
  self.transitionFacing = facing
  self.transitionProgress = 0
  self.transitionFrom = { x = self.worldX, y = self.worldY, z = self.worldZ }
  self.transitionTo = { x = target.x, y = target.y, z = target.z }
  return true
end

-- Source-side ladder ascent presentation. This never claims a field tile;
-- destination staging and the final semantic step own logical movement.
function FieldPlayer:beginTransitionLadderExit(facing)
  assert(type(facing) == "string", "ladder exit facing required")
  local target = { x = self.worldX, y = self.worldY + 2, z = self.worldZ }
  if facing == "south" then
    target.y = self.worldY + 0.5
    target.z = self.worldZ - 1.5
  end
  return beginTransitionPresentation(self, "ladder_exit", facing, target)
end

-- Source-side ladder descent presentation. It is deliberately separate from
-- ascent so the two source routines retain their opposite vertical motion.
function FieldPlayer:beginTransitionLadderDownExit(facing)
  assert(type(facing) == "string", "ladder-down exit facing required")
  return beginTransitionPresentation(self, "ladder_down_exit", facing, {
    x = self.worldX,
    y = self.worldY - 2,
    z = self.worldZ,
  })
end

-- Starts the sixteen-update vertical return from ladder staging to the
-- resolved anchor height. The caller performs the final cardinal tile step
-- only after this presentation interpolation completes.
function FieldPlayer:beginTransitionVerticalReturn(anchorY)
  assert(self.motion == "idle", "cannot begin a vertical return while moving")
  assert(type(anchorY) == "number", "ladder anchor height required")
  self.motion = "transition"
  self.progressTicks = 0
  self.durationTicks = 16
  self.transitionKind = "vertical_return"
  self.transitionFacing = nil
  self.transitionProgress = 0
  self.transitionFrom = { x = self.worldX, y = self.worldY, z = self.worldZ }
  self.transitionTo = { x = self.worldX, y = anchorY, z = self.worldZ }
  return true
end

function FieldPlayer:_advanceStep()
  assert(self.motion == "walking" and self.from and self.to, "walking step endpoints required")
  self.progressTicks = self.progressTicks + 1
  local progress = self.progressTicks / self.durationTicks
  self.worldX = self.from.worldX + (self.to.worldX - self.from.worldX) * progress
  self.worldZ = self.from.worldZ + (self.to.worldZ - self.from.worldZ) * progress
  if not self.to.sourceCellKey and self.from.surfaceId == self.to.surfaceId then
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
  if not self.to.sourceCellKey then
    self.surfaceId = self.to.surfaceId
  end
  self.committedSourceCellKey = self.to.sourceCellKey
  self.committedSourceSurfaceId = self.to.sourceSurfaceId
  self.motion = "idle"
  self.progressTicks = 0
  self.from, self.to = nil, nil
  return true
end

function FieldPlayer:_advanceJump()
  assert(self.motion == "jumping" and self.from and self.to, "jumping endpoints required")
  self.progressTicks = self.progressTicks + 1
  local progress = self.progressTicks / self.durationTicks
  self.worldX = self.from.worldX + (self.to.worldX - self.from.worldX) * progress
  self.worldZ = self.from.worldZ + (self.to.worldZ - self.from.worldZ) * progress
  local linearY = self.from.worldY + (self.to.worldY - self.from.worldY) * progress
  self.worldY = linearY + math.sin(math.pi * progress) * 0.5
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
      self.bufferedDirectionFresh = false
    end
    return self:_advanceStep()
  end

  if self.motion == "turning" then
    if input.pressedDirection then
      self.bufferedDirection = input.pressedDirection
      self.bufferedDirectionFresh = true
    end
    return self:_advanceTurn()
  end

  if self.motion == "jumping" then
    if input.pressedDirection then
      self.bufferedDirection = input.pressedDirection
      self.bufferedDirectionFresh = false
    end
    return self:_advanceJump()
  end

  if self.motion == "transition" then
    self.progressTicks = self.progressTicks + 1
    local progress = self.progressTicks / self.durationTicks
    self.transitionProgress = math.min(1, progress)
    self.worldX = self.transitionFrom.x + (self.transitionTo.x - self.transitionFrom.x) * progress
    self.worldY = self.transitionFrom.y + (self.transitionTo.y - self.transitionFrom.y) * progress
    self.worldZ = self.transitionFrom.z + (self.transitionTo.z - self.transitionFrom.z) * progress
    if self.progressTicks >= self.durationTicks then
      self.worldX, self.worldY, self.worldZ = self.transitionTo.x, self.transitionTo.y, self.transitionTo.z
      self.motion = "idle"
      self.progressTicks = 0
      self.transitionFrom, self.transitionTo = nil, nil
      self.transitionKind = nil
      self.transitionFacing = nil
      self.transitionProgress = nil
    end
    return true
  end

  local direction
  local isWalkingContinuation = false
  if self.bufferedDirection and (self.bufferedDirectionFresh or self.bufferedDirection == input.heldDirection) then
    direction = self.bufferedDirection
    isWalkingContinuation = not self.bufferedDirectionFresh and input.heldDirection == self.bufferedDirection
    self.bufferedDirectionFresh = false
  else
    self.bufferedDirection = nil
    self.bufferedDirectionFresh = false
    direction = input.pressedDirection or input.heldDirection
  end
  if not direction then
    return false
  end
  self.bufferedDirection = nil
  if not isWalkingContinuation and direction ~= self.facing then
    self:_beginTurn(direction)
    return self:_advanceTurn()
  end
  if self:tryStep(direction) then
    if self.motion == "jumping" then
      self:_advanceJump()
    else
      self:_advanceStep()
    end
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

-- Collapse the render pair after a fixed tick that did not advance movement.
-- Locked transition phases still render between fixed updates; retaining the
-- final pair of a scripted door step would replay that fraction throughout
-- the following door animation.
function FieldPlayer:collapseRenderInterpolation()
  assert(self.motion == "idle", "cannot collapse interpolation while the player is moving")
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = self.worldX, self.worldY, self.worldZ
end

-- Rebind the player to a newly committed physical coverage window. Global tile
-- coordinates remain authoritative; only local frame and composite surface id
-- change. Current and previous render positions receive the same frame delta.
function FieldPlayer:rebindCoverage(runtimeMap, deltaX, deltaY, deltaZ, cellKey, sourceSurfaceId)
  assert(runtimeMap and runtimeMap.coordinateOrigin, "coverage runtime map required")
  assert(
    type(deltaX) == "number" and type(deltaY) == "number" and type(deltaZ) == "number",
    "coverage rebase delta required"
  )
  assert(cellKey and sourceSurfaceId, "player source surface identity required")
  local oldPoint = projectPoint(self.currentMap, self.fieldX, self.fieldZ, cellKey, sourceSurfaceId)
  local point = projectPoint(runtimeMap, self.fieldX, self.fieldZ, cellKey, sourceSurfaceId)
  self.currentMap = runtimeMap
  self.resolver = SurfaceResolver.new(runtimeMap.terrain)
  local projectedLocalX, projectedLocalZ = point.localX, point.localZ
  assert(projectedLocalX % 1 == 0 and projectedLocalZ % 1 == 0, "projected local coordinates must be integers")
  ---@cast projectedLocalX integer
  ---@cast projectedLocalZ integer
  self.localX, self.localZ = projectedLocalX, projectedLocalZ
  self.surfaceId = point.surfaceId
  local frameDelta = {
    x = point.worldX - oldPoint.worldX,
    y = point.worldY - oldPoint.worldY,
    z = point.worldZ - oldPoint.worldZ,
  }
  self.worldX = self.worldX + frameDelta.x
  self.worldY = self.worldY + frameDelta.y
  self.worldZ = self.worldZ + frameDelta.z
  self.previousWorldX = self.previousWorldX + frameDelta.x
  self.previousWorldY = self.previousWorldY + frameDelta.y
  self.previousWorldZ = self.previousWorldZ + frameDelta.z
  self.committedSourceCellKey = cellKey
  self.committedSourceSurfaceId = sourceSurfaceId
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
    transitionKind = self.transitionKind,
    transitionProgress = self.transitionProgress,
  }
end

return FieldPlayer
