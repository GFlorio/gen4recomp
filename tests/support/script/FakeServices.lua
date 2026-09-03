-- Shared fake script-platform services for tests :
-- a deterministic in-memory world (flags, variables, seeded RNG), a small
-- actor world, a player, event collection, and stub facades for dialogue,
-- audio, camera, and maps. Tests construct one instance per scenario and
-- rewire individual services (for example `services.foreground.resolve`) as
-- needed. Everything here is pure Lua; no love dependency.

---@class FakeActor
---@field id string
---@field exists boolean
---@field visible boolean
---@field facing string
---@field fieldX integer
---@field fieldZ integer
---@field worldY number
---@field movementType string|nil
---@field animationPaused boolean
---@field numericId integer|nil
---@field presentationOffset { x: number, y: number, z: number }
---@field movementOwner string|nil
---@field movementState table|nil
---@field _scriptedAction table|nil
---@field _scriptedStart { fieldX: integer, fieldZ: integer }|nil
---@field _scriptedDest { fieldX: integer, fieldZ: integer }|nil

---@class FakeWorld
---@field flags table<string, boolean>
---@field variables table<string, integer>
---@field calls table[]
---@field rng table|nil
local FakeWorld = {}
FakeWorld.__index = FakeWorld

---@return FakeWorld
function FakeWorld.new()
  return setmetatable({
    flags = {},
    variables = {},
    calls = {},
  }, FakeWorld)
end

function FakeWorld:isFlagSet(id)
  return self.flags[id] == true
end

function FakeWorld:setFlag(id)
  self.flags[id] = true
  self.calls[#self.calls + 1] = { op = "setFlag", id = id }
end

function FakeWorld:clearFlag(id)
  self.flags[id] = nil
  self.calls[#self.calls + 1] = { op = "clearFlag", id = id }
end

function FakeWorld:getVar(id)
  return self.variables[id] or 0
end

function FakeWorld:setVar(id, value)
  self.variables[id] = value
  self.calls[#self.calls + 1] = { op = "setVar", id = id, value = value }
end

function FakeWorld:addVar(id, amount)
  self:setVar(id, self:getVar(id) + amount)
end

function FakeWorld:subVar(id, amount)
  self:setVar(id, self:getVar(id) - amount)
end

-- Deterministic Lehmer-style RNG : never math.random.
---@param seed integer?
---@return table rng
function FakeWorld:newRng(seed)
  local rng = { _seed = seed or 0x2545F491 }
  function rng:nextRaw()
    self._seed = (self._seed * 48271) % 0x7FFFFFFF
    return self._seed
  end
  function rng:nextInt(maxExclusive)
    assert(maxExclusive > 0, "maxExclusive must be positive")
    return self:nextRaw() % maxExclusive
  end
  function rng:range(minInclusive, maxInclusive)
    local span = maxInclusive - minInclusive + 1
    return minInclusive + self:nextRaw() % span
  end
  function rng:chance(numerator, denominator)
    return self:nextRaw() % denominator < numerator
  end
  return rng
end

---@class FakeActors
---@field actors table<string, FakeActor>
---@field partner string|nil
---@field mapIndexes table<integer, string>|nil
---@field cameraTarget string|nil
local FakeActors = {}
FakeActors.__index = FakeActors

-- Test-only mirror of the semantic jump distance contract: one named distance
-- displaces a fixed number of cells. This stays local so the shared fake
-- does not import production calibration for test convenience.
local FAKE_JUMP_TILES = {
  zero = 0,
  near = 1,
  far = 1,
  farther = 3,
}

local function fakeJumpTiles(distance)
  return assert(FAKE_JUMP_TILES[distance], "unknown jump distance " .. tostring(distance))
end

---@return FakeActors
function FakeActors.new()
  return setmetatable({ actors = {}, partner = nil, mapIndexes = nil, cameraTarget = nil }, FakeActors)
end

---@param id string
---@param opts table|nil
---@return FakeActor
function FakeActors:add(id, opts)
  opts = opts or {}
  local actor = {
    id = id,
    exists = opts.exists ~= false,
    visible = opts.visible ~= false,
    facing = opts.facing or "south",
    fieldX = opts.fieldX or 0,
    fieldZ = opts.fieldZ or 0,
    worldY = opts.worldY or 0,
    movementType = opts.movementType,
    animationPaused = false,
    numericId = opts.numericId,
    presentationOffset = { x = 0, y = 0, z = 0 },
    movementOwner = nil,
  }
  self.actors[id] = actor
  return actor
end

function FakeActors:resolve(ref, trigger)
  if type(ref) == "table" and ref.special == "player" then
    return "player"
  end
  if type(ref) == "table" and ref.special == "self" then
    return trigger and trigger.selfActor or nil
  end
  if type(ref) == "table" and ref.special == "last_talked" then
    return trigger and trigger.selfActor or nil
  end
  if type(ref) == "table" and ref.special == "partner" then
    return self.partner
  end
  if type(ref) == "table" then
    return ref.id
  end
  return ref
end

function FakeActors:exists(actorId)
  local actor = self.actors[actorId]
  return actor ~= nil and actor.exists
end

function FakeActors:show(actorId)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  actor.visible = true
end

function FakeActors:hide(actorId)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  actor.visible = false
end

function FakeActors:isVisible(actorId)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  return actor.visible ~= false
end

function FakeActors:setPresentationOffset(actorId, offset)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  assert(
    type(offset) == "table" and type(offset.x) == "number" and type(offset.y) == "number" and type(offset.z) == "number",
    "presentation offset requires x,y,z"
  )
  actor.presentationOffset = { x = offset.x, y = offset.y, z = offset.z }
end

function FakeActors:clearPresentationOffset(actorId)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  actor.presentationOffset = { x = 0, y = 0, z = 0 }
end

function FakeActors:setPosition(actorId, position)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  actor.fieldX = position.fieldX
  actor.fieldZ = position.fieldZ
  if position.worldY ~= nil then
    actor.worldY = position.worldY
  end
end

function FakeActors:setFacing(actorId, direction)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  actor.facing = direction
end

function FakeActors:setMovementType(actorId, movementType)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  actor.movementType = movementType
end

function FakeActors:setAnimationPaused(actorId, paused)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  actor.animationPaused = paused == true
end

function FakeActors:beginScriptedAction(actorId, action)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  if action.action == "face" then
    if action.direction ~= nil then
      actor.facing = action.direction
    end
    actor._scriptedAction = action
    return
  end
  if action.action == "walk" then
    local dx, dz = 0, 0
    if action.direction == "east" then
      dx = 1
    elseif action.direction == "west" then
      dx = -1
    elseif action.direction == "north" then
      dz = -1
    elseif action.direction == "south" then
      dz = 1
    end
    if action.distance == "zero" then
      dx, dz = 0, 0
    end
    actor._scriptedStart = { fieldX = actor.fieldX, fieldZ = actor.fieldZ }
    actor._scriptedDest = { fieldX = actor.fieldX + dx, fieldZ = actor.fieldZ + dz }
  elseif action.action == "jump" then
    actor._scriptedStart = { fieldX = actor.fieldX, fieldZ = actor.fieldZ }
    local dx, dz = 0, 0
    if action.direction == "east" then
      dx = 1
    elseif action.direction == "west" then
      dx = -1
    elseif action.direction == "north" then
      dz = -1
    elseif action.direction == "south" then
      dz = 1
    end
    local steps = fakeJumpTiles(action.distance)
    actor._scriptedDest = { fieldX = actor.fieldX + dx * steps, fieldZ = actor.fieldZ + dz * steps }
  elseif
    action.action == "walk_in_place"
    or action.action == "delay"
    or action.action == "emote"
    or action.action == "gesture"
  then
    actor._scriptedStart = { fieldX = actor.fieldX, fieldZ = actor.fieldZ }
    actor._scriptedDest = { fieldX = actor.fieldX, fieldZ = actor.fieldZ }
  else
    actor._scriptedStart = { fieldX = actor.fieldX, fieldZ = actor.fieldZ }
    actor._scriptedDest = { fieldX = actor.fieldX, fieldZ = actor.fieldZ }
  end
  actor._scriptedAction = action
end

function FakeActors:advanceScriptedAction(_, _, _) end

function FakeActors:commitScriptedAction(actorId)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  if actor._scriptedAction and actor._scriptedDest then
    local kind = actor._scriptedAction.action
    if kind == "walk" or kind == "jump" then
      actor.fieldX = actor._scriptedDest.fieldX
      actor.fieldZ = actor._scriptedDest.fieldZ
    elseif kind == "face" then
      if actor._scriptedAction.direction ~= nil then
        actor.facing = actor._scriptedAction.direction
      end
    end
  end
  actor._scriptedStart = nil
  actor._scriptedDest = nil
  actor._scriptedAction = nil
end

function FakeActors:cancelScriptedMovement(actorId)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  if actor._scriptedStart then
    actor.fieldX = actor._scriptedStart.fieldX
    actor.fieldZ = actor._scriptedStart.fieldZ
  end
  actor._scriptedStart = nil
  actor._scriptedDest = nil
  actor._scriptedAction = nil
end

function FakeActors:isScriptedMoving(actorId)
  local actor = self.actors[actorId]
  return actor ~= nil and actor._scriptedAction ~= nil
end

function FakeActors:isPausable(actorId)
  local actor = self.actors[actorId]
  return actor == nil or actor._scriptedAction == nil
end

function FakeActors:allPausable()
  for actorId in pairs(self.actors) do
    if not self:isPausable(actorId) then
      return false
    end
  end
  return true
end

function FakeActors:getPosition(actorId)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  return { fieldX = actor.fieldX, fieldZ = actor.fieldZ, worldY = actor.worldY }
end

function FakeActors:getFacing(actorId)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  return actor.facing
end

function FakeActors:id(actorId)
  local actor = self.actors[actorId]
  return actor and actor.numericId
end

function FakeActors:partnerId()
  return self.partner
end

-- Resolve a numeric local map-object index through the fixture map:
-- index -> actor id, or nil when no fixture mapping exists.
---@param index integer
---@return string|nil
function FakeActors:actorIdForMapIndex(index)
  if self.mapIndexes == nil then
    return nil
  end
  return self.mapIndexes[index]
end

-- The fixture camera target actor; nil by default.
---@return string|nil
function FakeActors:cameraTargetId()
  return self.cameraTarget
end

function FakeActors:snapshot(actorId)
  local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
  return {
    actorId = actor.id,
    position = { fieldX = actor.fieldX, fieldZ = actor.fieldZ, worldY = actor.worldY },
    facing = actor.facing,
    visible = actor.visible,
    movementType = actor.movementType,
  }
end

---@class FakePlayer
---@field fieldX integer
---@field fieldZ integer
---@field worldY number
---@field _facing string
---@field _gender number
---@field _name string
local FakePlayer = {}
FakePlayer.__index = FakePlayer

---@param opts table?
---@return FakePlayer
function FakePlayer.new(opts)
  opts = opts or {}
  return setmetatable({
    fieldX = opts.fieldX or 10,
    fieldZ = opts.fieldZ or 10,
    worldY = opts.worldY or 0,
    _facing = opts.facing or "south",
    _gender = opts.gender or 0,
    _name = opts.name or "Gold",
  }, FakePlayer)
end

function FakePlayer:position()
  return { fieldX = self.fieldX, fieldZ = self.fieldZ, worldY = self.worldY }
end

function FakePlayer:facing()
  return self._facing
end
function FakePlayer:gender()
  return self._gender
end
function FakePlayer:name()
  return self._name
end

function FakePlayer:turn(direction)
  self._facing = direction
end

function FakePlayer:setScriptPosition(position)
  self.fieldX = position.fieldX
  self.fieldZ = position.fieldZ
  if position.worldY ~= nil then
    self.worldY = position.worldY
  end
end

function FakePlayer:beginScriptedAction(action)
  if action.action == "face" then
    if action.direction ~= nil then
      self._facing = action.direction
    end
    return
  end
  self._scriptedStart = { fieldX = self.fieldX, fieldZ = self.fieldZ, worldY = self.worldY }
  if action.action == "walk" then
    local dx, dz = 0, 0
    if action.direction == "east" then
      dx = 1
    elseif action.direction == "west" then
      dx = -1
    elseif action.direction == "north" then
      dz = -1
    elseif action.direction == "south" then
      dz = 1
    end
    if action.distance == "zero" then
      dx, dz = 0, 0
    end
    self._scriptedDest = { fieldX = self.fieldX + dx, fieldZ = self.fieldZ + dz, worldY = self.worldY }
  elseif action.action == "jump" then
    local dx, dz = 0, 0
    if action.direction == "east" then
      dx = 1
    elseif action.direction == "west" then
      dx = -1
    elseif action.direction == "north" then
      dz = -1
    elseif action.direction == "south" then
      dz = 1
    end
    local steps = fakeJumpTiles(action.distance)
    self._scriptedDest = { fieldX = self.fieldX + dx * steps, fieldZ = self.fieldZ + dz * steps, worldY = self.worldY }
  else
    self._scriptedDest = { fieldX = self.fieldX, fieldZ = self.fieldZ, worldY = self.worldY }
  end
  self._scriptedAction = action
end

function FakePlayer:advanceScriptedAction(_, _) end

function FakePlayer:commitScriptedAction()
  if self._scriptedDest then
    self.fieldX = self._scriptedDest.fieldX
    self.fieldZ = self._scriptedDest.fieldZ
    self.worldY = self._scriptedDest.worldY
    if self._scriptedAction and self._scriptedAction.direction then
      local kind = self._scriptedAction.action
      if kind == "walk" or kind == "jump" or kind == "walk_in_place" then
        self._facing = self._scriptedAction.direction
      end
    end
  end
  self._scriptedStart = nil
  self._scriptedDest = nil
  self._scriptedAction = nil
end

function FakePlayer:cancelScriptedMovement()
  if self._scriptedStart then
    self.fieldX = self._scriptedStart.fieldX
    self.fieldZ = self._scriptedStart.fieldZ
    self.worldY = self._scriptedStart.worldY
  end
  self._scriptedStart = nil
  self._scriptedDest = nil
  self._scriptedAction = nil
end

function FakePlayer:isScriptedMoving()
  return self._scriptedAction ~= nil
end

---@class FakeEvents
---@field records table[]
local FakeEvents = {}
FakeEvents.__index = FakeEvents

---@return FakeEvents
function FakeEvents.new()
  return setmetatable({ records = {} }, FakeEvents)
end

function FakeEvents:emit(name, payload)
  if self.records == nil then
    error("FakeEvents.emit self lacks records: " .. tostring(self) .. " name=" .. tostring(name))
  end
  self.records[#self.records + 1] = { name = name, payload = payload }
end

-- The first recorded payload of `name` attributed to `instanceId`, or nil.
-- Ended script instances are not retained by the scheduler, so script.error
-- and script.ended events are the end-state observation surface.
---@param name string
---@param instanceId string
---@return table|nil
function FakeEvents:eventFor(name, instanceId)
  for _, record in ipairs(self.records) do
    if record.name == name and record.payload.instanceId == instanceId then
      return record.payload
    end
  end
  return nil
end

---@class FakeServices
---@field world FakeWorld|FieldEventState
---@field actors FakeActors|ScriptActorWorld
---@field player FakePlayer
---@field events FakeEvents
---@field dialogue table|nil
---@field audio table|nil
---@field camera table|nil
---@field maps table|nil
---@field screen table|nil
---@field advanceAsync fun(tick: integer)|nil
---@field foreground { resolve: fun(input: table|nil): table|nil }|nil
---@field resolveComposition fun(scriptId: string): table|nil|nil
---@field menu table
---@field scriptMenu table
---@field signpost ScriptSignpostHost|nil
---@field windowStyles { resolve: fun(registry: table, id: string): table|nil }|nil the immutable window-style catalogue surface the high-level sign ops resolve appearances against
---@field startMenuReopen { request: fun() }|nil the opcode-61 Start Menu reopen hook boundary
---@field auxiliaryUi AuxiliaryFieldUi
local FakeServices = {}
FakeServices.__index = FakeServices

---@param opts table|nil
---@return FakeServices
function FakeServices.new(opts)
  opts = opts or {}
  local world = FakeWorld.new()
  return setmetatable({
    world = world,
    actors = FakeActors.new(),
    player = FakePlayer.new(opts.player),
    events = FakeEvents.new(),
    dialogue = opts.dialogue,
    audio = opts.audio,
    camera = opts.camera,
    maps = opts.maps,
    screen = opts.screen,
    advanceAsync = opts.advanceAsync,
    foreground = nil,
    resolveComposition = nil,
  }, FakeServices)
end

function FakeServices:withRng(seed)
  self.world.rng = self.world:newRng(seed)
  return self
end

return FakeServices
