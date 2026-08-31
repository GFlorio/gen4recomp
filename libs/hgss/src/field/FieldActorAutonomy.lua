-- Executes the ordinary semantic movement profiles for one field actor.
-- Physical legality and presentation remain manager-owned; this module only
-- advances source-shaped controller state and asks its capability to act.

local FieldObjectMovement = require("libs.assets.src.FieldObjectMovement")

---@class FieldActorAutonomy
---@field rng table
---@field profiles table
---@field states table<string, table>
local FieldActorAutonomy = {}
FieldActorAutonomy.__index = FieldActorAutonomy

local OPPOSITE = { north = "south", south = "north", west = "east", east = "west" }
local WAIT_CHOICES = { 16, 32, 48, 64 }
local ROTATION_INTERVAL = 24

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function directionIndex(directions, direction)
  for index, candidate in ipairs(directions) do
    if candidate == direction then
      return index
    end
  end
  return 1
end

local function wait(rng, profile)
  local choices = profile.waitChoices or WAIT_CHOICES
  return choices[rng:nextInt(#choices) + 1]
end

local function playerDirection(state, capability)
  local player = capability.player
  if not state.profile.nearbyPlayerFacing or player == nil then
    return nil
  end
  if state.sourceEvent.type ~= 1 and state.sourceEvent.type ~= 2 then
    return nil
  end
  local radius = state.sourceEvent.param0
  assert(type(radius) == "number", "nearby-player radius is required")
  if math.abs(player.fieldX - state.fieldX) > radius or math.abs(player.fieldZ - state.fieldZ) > radius then
    return nil
  end
  if player.surfaceId ~= nil and state.surfaceId ~= nil and player.surfaceId ~= state.surfaceId then
    return nil
  end
  if player.worldY ~= nil and state.worldY ~= nil and math.abs(player.worldY - state.worldY) > 1.25 then
    return nil
  end

  local candidates = {}
  if player.fieldZ < state.fieldZ then
    candidates.north = true
  elseif player.fieldZ > state.fieldZ then
    candidates.south = true
  end
  if player.fieldX < state.fieldX then
    candidates.west = true
  elseif player.fieldX > state.fieldX then
    candidates.east = true
  end
  for _, direction in ipairs(state.profile.directions or state.profile.sequence or {}) do
    if candidates[direction] then
      return direction
    end
  end
  return nil
end

local function resetState(state, movementType, profile)
  state.movementType = movementType
  state.profile = profile
  state.timer = 0
  state.sequenceIndex = directionIndex(profile.sequence or {}, state.initialFacing)
  state.rotationIndex = directionIndex(profile.sequence or {}, state.initialFacing)
  state.shuttleDirection = state.initialFacing
  state.blocked = false
end

---@class FieldActorAutonomyOptions
---@field rng table
---@field profiles table|{ require: fun(self: table, movementType: string): table }?

---@param opts FieldActorAutonomyOptions
---@return FieldActorAutonomy
function FieldActorAutonomy.new(opts)
  assert(type(opts) == "table" and opts.rng, "field actor autonomy requires an RNG")
  local profiles = opts.profiles or FieldObjectMovement
  assert(type(profiles.require) == "function", "field actor autonomy requires a profile lookup")
  return setmetatable({ rng = opts.rng, profiles = profiles, states = {} }, FieldActorAutonomy)
end

---@param actorId string
---@param movementType string
---@param sourceEvent table
function FieldActorAutonomy:attach(actorId, movementType, sourceEvent)
  assert(self.states[actorId] == nil, "field actor autonomy is already attached: " .. actorId)
  local profile = self.profiles.require(movementType)
  local state = {
    actorId = actorId,
    movementType = movementType,
    profile = profile,
    sourceEvent = sourceEvent,
    initialFacing = sourceEvent.facingDirection,
    fieldX = sourceEvent.x,
    fieldZ = sourceEvent.z,
    surfaceId = nil,
    worldY = sourceEvent.y / 16,
    timer = 0,
    sequenceIndex = 1,
    rotationIndex = 1,
    shuttleDirection = sourceEvent.facingDirection,
    blocked = false,
  }
  resetState(state, movementType, profile)
  self.states[actorId] = state
end

---@param actorId string
function FieldActorAutonomy:detach(actorId)
  self.states[actorId] = nil
end

---@param actorId string
---@param movementType string
---@param defer boolean?
function FieldActorAutonomy:setMovementType(actorId, movementType, defer)
  local state = assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId)
  local profile = self.profiles.require(movementType)
  if defer then
    state.pendingMovementType = movementType
    return
  end
  resetState(state, movementType, profile)
end

function FieldActorAutonomy:applyPendingMovementType(actorId)
  local state = assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId)
  if state.pendingMovementType then
    local movementType = state.pendingMovementType
    state.pendingMovementType = nil
    self:setMovementType(actorId, movementType)
  end
end

---@param actorId string
---@return table
function FieldActorAutonomy:state(actorId)
  return copy(assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId))
end

---@param actorId string
---@return boolean
function FieldActorAutonomy:isOrdinary(actorId)
  return assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId).profile.kind ~= "special"
end

local function stepLook(self, state, capability)
  if state.timer > 0 then
    state.timer = state.timer - 1
    return
  end
  local direction = playerDirection(state, capability)
  if direction == nil then
    local directions = assert(state.profile.directions)
    direction = directions[self.rng:nextInt(#directions) + 1]
  end
  capability:setFacing(state.actorId, direction)
  state.timer = wait(self.rng, state.profile)
end

local function stepWander(self, state, capability)
  if state.timer > 0 then
    state.timer = state.timer - 1
    return
  end
  local directions = assert(state.profile.directions)
  local direction = directions[self.rng:nextInt(#directions) + 1]
  capability:setFacing(state.actorId, direction)
  capability:walk(state.actorId, direction)
  state.timer = wait(self.rng, state.profile)
end

local function stepRotate(_, state, capability)
  if state.timer > 0 then
    state.timer = state.timer - 1
    return
  end
  local sequence = assert(state.profile.sequence)
  state.rotationIndex = state.rotationIndex % #sequence + 1
  local direction = playerDirection(state, capability) or sequence[state.rotationIndex]
  capability:setFacing(state.actorId, direction)
  state.timer = state.profile.rotationInterval or ROTATION_INTERVAL
end

local function stepPattern(state, capability)
  local sequence = assert(state.profile.sequence)
  local direction = sequence[state.sequenceIndex]
  capability:setFacing(state.actorId, direction)
  if capability:walk(state.actorId, direction) then
    state.sequenceIndex = state.sequenceIndex % #sequence + 1
    state.blocked = false
    return
  end
  state.blocked = true
  state.sequenceIndex = state.sequenceIndex % #sequence + 1
  direction = sequence[state.sequenceIndex]
  capability:setFacing(state.actorId, direction)
  if capability:walk(state.actorId, direction) then
    state.sequenceIndex = state.sequenceIndex % #sequence + 1
  end
end

local function stepShuttle(state, capability)
  local direction = state.shuttleDirection
  capability:setFacing(state.actorId, direction)
  if capability:walk(state.actorId, direction) then
    state.blocked = false
    return
  end
  state.blocked = true
  state.shuttleDirection = OPPOSITE[direction]
  capability:setFacing(state.actorId, state.shuttleDirection)
  capability:walk(state.actorId, state.shuttleDirection)
end

local function stepSpin(state, capability)
  -- The slot-49 controller is a four-facing, non-translating spin. Its
  -- handler advances one quarter turn every four field updates.
  state.timer = state.timer - 1
  if state.timer > 0 then
    return
  end
  state.timer = 4
  state.rotationIndex = state.rotationIndex % 4 + 1
  capability:setFacing(state.actorId, ({ "north", "east", "south", "west" })[state.rotationIndex])
end

---@param actorId string
---@param capability table
function FieldActorAutonomy:step(actorId, capability)
  local state = assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId)
  state.fieldX = assert(capability.fieldX)
  state.fieldZ = assert(capability.fieldZ)
  state.surfaceId = capability.surfaceId
  state.worldY = capability.worldY
  if state.profile.kind == "special" then
    return
  elseif state.profile.kind == "stationary" then
    if state.profile.fixedFacing and not capability.facingOverride then
      capability:setFacing(actorId, state.profile.fixedFacing)
    end
  elseif state.profile.kind == "look" then
    stepLook(self, state, capability)
  elseif state.profile.kind == "wander" then
    stepWander(self, state, capability)
  elseif state.profile.kind == "rotate" then
    stepRotate(self, state, capability)
  elseif state.profile.kind == "pattern" then
    stepPattern(state, capability)
  elseif state.profile.kind == "shuttle" then
    stepShuttle(state, capability)
  elseif state.profile.kind == "spin" then
    stepSpin(state, capability)
  else
    error("unsupported field actor autonomy profile kind " .. tostring(state.profile.kind))
  end
end

return FieldActorAutonomy
