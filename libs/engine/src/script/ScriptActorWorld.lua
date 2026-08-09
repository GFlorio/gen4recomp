-- Script actor world adapter: the script layer's stable view of field actors,
-- backed by an injected actor manager (the concrete NPC implementation is
-- never imported here). The adapter resolves the special `player` actor
-- through the injected player facade and keeps a serializable read-only
-- snapshot contract. Missing actors surface as nil from `get`/`exists`; the
-- runtime converts them into attributed errors. Pure domain module: no love
-- dependency.

---@class ScriptActorManager
---@field getActor fun(self: ScriptActorManager, actorId: string): table|nil
---@field show fun(self: ScriptActorManager, actorId: string)|nil
---@field hide fun(self: ScriptActorManager, actorId: string)|nil
---@field setPosition fun(self: ScriptActorManager, actorId: string, position: table)|nil
---@field setFacing fun(self: ScriptActorManager, actorId: string, direction: string)|nil
---@field setMovementType fun(self: ScriptActorManager, actorId: string, movementType: string)|nil
---@field getPosition fun(self: ScriptActorManager, actorId: string): table|nil
---@field getFacing fun(self: ScriptActorManager, actorId: string): string|nil
---@field isBusy fun(self: ScriptActorManager, actorId: string): boolean|nil
---@field canMove fun(self: ScriptActorManager, actorId: string, direction: string): boolean|nil
---@field numericId fun(self: ScriptActorManager, actorId: string): integer|nil
---@field partnerId fun(self: ScriptActorManager): string|nil
---@field actorIdForMapIndex fun(self: ScriptActorManager, index: integer): string|nil|nil
---@field cameraTargetId fun(self: ScriptActorManager): string|nil|nil

---@class ScriptActorWorld
---@field private _manager ScriptActorManager
---@field private _player table|nil
local ScriptActorWorld = {}
ScriptActorWorld.__index = ScriptActorWorld

---@param manager ScriptActorManager
---@param player table|nil player facade { position, facing, gender, name }
---@return ScriptActorWorld
function ScriptActorWorld.new(manager, player)
  assert(manager and type(manager.getActor) == "function", "actor world requires an actor manager with getActor")
  return setmetatable({
    _manager = manager,
    _player = player,
  }, ScriptActorWorld)
end

-- The player is always a valid script actor.
---@param actorId string
---@return boolean
function ScriptActorWorld:exists(actorId)
  if actorId == "player" then
    return true
  end
  return self._manager:getActor(actorId) ~= nil
end

-- Resolve a numeric local map-object index to the current map's actor id
-- (the pinned HGSS object-id path); nil when the map has no such object.
---@param index integer
---@return string|nil
function ScriptActorWorld:actorIdForMapIndex(index)
  if self._manager.actorIdForMapIndex == nil then
    return nil
  end
  return self._manager:actorIdForMapIndex(index)
end

-- The field camera target actor (pinned HGSS object id 0xF1); nil when the
-- session has no camera target.
---@return string|nil
function ScriptActorWorld:cameraTargetId()
  if self._manager.cameraTargetId == nil then
    return nil
  end
  return self._manager:cameraTargetId()
end

-- Serializable read-only snapshot of one actor ; nil when
-- the actor is not live.
---@param actorId string
---@return table|nil
function ScriptActorWorld:snapshot(actorId)
  if actorId == "player" then
    local player = self._player
    if player == nil then
      return nil
    end
    local position = player:position()
    return {
      actorId = "player",
      position = position,
      facing = player:facing(),
      visible = true,
    }
  end
  local actor = self._manager:getActor(actorId)
  if actor == nil then
    return nil
  end
  local position = self._manager.getPosition and self._manager:getPosition(actorId)
  local facing = self._manager.getFacing and self._manager:getFacing(actorId)
  return {
    actorId = actorId,
    position = position,
    facing = facing,
    visible = true,
  }
end

function ScriptActorWorld:show(actorId)
  if actorId == "player" then
    return
  end
  assert(self._manager.show, "actor manager does not support show")
  self._manager:show(actorId)
end

function ScriptActorWorld:hide(actorId)
  if actorId == "player" then
    return
  end
  assert(self._manager.hide, "actor manager does not support hide")
  self._manager:hide(actorId)
end

---@param actorId string
---@param position table { fieldX, fieldZ, worldY? }
function ScriptActorWorld:setPosition(actorId, position)
  if actorId == "player" then
    if self._player and self._player.setPosition then
      self._player:setPosition(position)
    end
    return
  end
  assert(self._manager.setPosition, "actor manager does not support setPosition")
  self._manager:setPosition(actorId, position)
end

---@param actorId string
---@param direction string
function ScriptActorWorld:setFacing(actorId, direction)
  if actorId == "player" then
    if self._player and self._player.turn then
      self._player:turn(direction)
    end
    return
  end
  assert(self._manager.setFacing, "actor manager does not support setFacing")
  self._manager:setFacing(actorId, direction)
end

---@param actorId string
---@param movementType string
function ScriptActorWorld:setMovementType(actorId, movementType)
  if actorId == "player" then
    return
  end
  assert(self._manager.setMovementType, "actor manager does not support setMovementType")
  self._manager:setMovementType(actorId, movementType)
end

---@param actorId string
---@return table
function ScriptActorWorld:getPosition(actorId)
  if actorId == "player" then
    assert(self._player, "no player facade for the script actor world")
    return self._player:position()
  end
  assert(self._manager.getPosition, "actor manager does not support getPosition")
  local position = self._manager:getPosition(actorId)
  assert(position ~= nil, "actor world position missing for " .. actorId)
  return position
end

---@param actorId string
---@return string
function ScriptActorWorld:getFacing(actorId)
  if actorId == "player" then
    assert(self._player, "no player facade for the script actor world")
    return self._player:facing()
  end
  assert(self._manager.getFacing, "actor manager does not support getFacing")
  local facing = self._manager:getFacing(actorId)
  assert(facing ~= nil, "actor world facing missing for " .. actorId)
  return facing
end

---@param actorId string
---@return boolean
function ScriptActorWorld:isBusy(actorId)
  if actorId == "player" then
    return false
  end
  if not self._manager.isBusy then
    return false
  end
  return self._manager:isBusy(actorId) or false
end

---@param actorId string
---@param direction string
---@return boolean
function ScriptActorWorld:canMove(actorId, direction)
  if actorId == "player" then
    return true
  end
  if not self._manager.canMove then
    return self:exists(actorId)
  end
  return self._manager:canMove(actorId, direction) or false
end

---@param actorId string
---@return integer|nil
function ScriptActorWorld:id(actorId)
  if not self._manager.numericId then
    return nil
  end
  return self._manager:numericId(actorId)
end

---@return string|nil
function ScriptActorWorld:partnerId()
  if not self._manager.partnerId then
    return nil
  end
  return self._manager:partnerId()
end

return ScriptActorWorld
