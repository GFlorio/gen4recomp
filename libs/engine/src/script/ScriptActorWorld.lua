-- Script actor world adapter: the script layer's stable view of field actors,
-- backed by an injected actor manager (the concrete NPC implementation is
-- never imported here). The adapter resolves the special `player` actor
-- through the injected player facade and keeps a serializable read-only
-- snapshot contract. The constructor requires the complete manager interface:
-- a missing capability is a construction error, never a silent nil. Missing
-- actors surface as nil from `get`/`exists`; the runtime converts them into
-- attributed errors. Pure domain module: no love dependency.

---@class ScriptActorManager
---@field getActor fun(self: ScriptActorManager, actorId: string): table|nil
---@field show fun(self: ScriptActorManager, actorId: string)
---@field hide fun(self: ScriptActorManager, actorId: string)
---@field setPosition fun(self: ScriptActorManager, actorId: string, position: table)
---@field setFacing fun(self: ScriptActorManager, actorId: string, direction: string)
---@field setMovementType fun(self: ScriptActorManager, actorId: string, movementType: string)
---@field setAnimationPaused fun(self: ScriptActorManager, actorId: string, paused: boolean)
---@field getPosition fun(self: ScriptActorManager, actorId: string): table
---@field getFacing fun(self: ScriptActorManager, actorId: string): string
---@field numericId fun(self: ScriptActorManager, actorId: string): integer|nil
---@field actorIdForMapIndex fun(self: ScriptActorManager, index: integer): string|nil
---@field cameraTargetId fun(self: ScriptActorManager): string|nil
---@field partnerId fun(self: ScriptActorManager): string|nil

-- The manager methods the actor world calls; every one must be present.
local REQUIRED_MANAGER_METHODS = {
  "getActor",
  "show",
  "hide",
  "setPosition",
  "setFacing",
  "setMovementType",
  "setAnimationPaused",
  "getPosition",
  "getFacing",
  "numericId",
  "actorIdForMapIndex",
  "cameraTargetId",
  "partnerId",
}

---@class ScriptActorWorld
---@field private _manager ScriptActorManager
---@field private _player table player facade { position, facing, gender, name }
local ScriptActorWorld = {}
ScriptActorWorld.__index = ScriptActorWorld

---@param manager ScriptActorManager
---@param player table player facade { position, facing, gender, name }
---@return ScriptActorWorld
function ScriptActorWorld.new(manager, player)
  assert(manager and type(manager) == "table", "actor world requires an actor manager")
  for _, method in ipairs(REQUIRED_MANAGER_METHODS) do
    assert(type(manager[method]) == "function", "actor manager must implement " .. method)
  end
  assert(
    player and type(player.position) == "function" and type(player.facing) == "function",
    "actor world requires the player facade (position, facing)"
  )
  return setmetatable({
    _manager = manager,
    _player = player,
  }, ScriptActorWorld)
end

-- The player is a valid script actor only while the facade is live.
---@param actorId string
---@return boolean
function ScriptActorWorld:exists(actorId)
  if actorId == "player" then
    return self._player ~= nil
  end
  return self._manager:getActor(actorId) ~= nil
end

-- Resolve a numeric local map-object index to the current map's actor id
-- (the pinned HGSS object-id path); nil when the map has no such object.
---@param index integer
---@return string|nil
function ScriptActorWorld:actorIdForMapIndex(index)
  return self._manager:actorIdForMapIndex(index)
end

-- The field camera target actor (pinned HGSS object id 241); nil when the
-- session has no camera target.
---@return string|nil
function ScriptActorWorld:cameraTargetId()
  return self._manager:cameraTargetId()
end

-- The walking partner actor (pinned HGSS object id 253); nil while no
-- Pokémon follows the player.
---@return string|nil
function ScriptActorWorld:partnerId()
  return self._manager:partnerId()
end

-- Serializable read-only snapshot of one actor; nil when
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
  local position = self._manager:getPosition(actorId)
  local facing = self._manager:getFacing(actorId)
  return {
    actorId = actorId,
    position = position,
    facing = facing,
    -- Scripted hide_object is transient visibility on the live actor: the
    -- snapshot reports the same state collision sees (hidden actors remain
    -- solid), so the two views never contradict.
    visible = actor.visible ~= false,
  }
end

function ScriptActorWorld:show(actorId)
  if actorId == "player" then
    return
  end
  self._manager:show(actorId)
end

function ScriptActorWorld:hide(actorId)
  if actorId == "player" then
    return
  end
  self._manager:hide(actorId)
end

---@param actorId string
---@param position table { fieldX, fieldZ, worldY? }
function ScriptActorWorld:setPosition(actorId, position)
  if actorId == "player" then
    if self._player.setPosition ~= nil then
      self._player:setPosition(position)
    end
    return
  end
  self._manager:setPosition(actorId, position)
end

---@param actorId string
---@param direction string
function ScriptActorWorld:setFacing(actorId, direction)
  if actorId == "player" then
    if self._player.turn ~= nil then
      self._player:turn(direction)
    end
    return
  end
  self._manager:setFacing(actorId, direction)
end

---@param actorId string
---@param movementType string
function ScriptActorWorld:setMovementType(actorId, movementType)
  if actorId == "player" then
    return
  end
  self._manager:setMovementType(actorId, movementType)
end

---@param actorId string
---@param paused boolean
function ScriptActorWorld:setAnimationPaused(actorId, paused)
  if actorId == "player" then
    return
  end
  self._manager:setAnimationPaused(actorId, paused)
end

---@param actorId string
---@return table
function ScriptActorWorld:getPosition(actorId)
  if actorId == "player" then
    assert(self._player, "no player facade for the script actor world")
    return self._player:position()
  end
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
  local facing = self._manager:getFacing(actorId)
  assert(facing ~= nil, "actor world facing missing for " .. actorId)
  return facing
end

---@param actorId string
---@return integer|nil
function ScriptActorWorld:id(actorId)
  return self._manager:numericId(actorId)
end

return ScriptActorWorld
