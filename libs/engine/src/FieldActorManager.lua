-- Owns the object actors of every runtime map the session currently holds, plus
-- the occupancy index they contribute to collision. Visibility follows
-- pret/pokeheartgold's rule that an object exists only while its event flag is
-- clear (`src/map_object.c`), so this manager subscribes to FieldEventState and
-- applies queued changes on one fixed-tick boundary: an actor never draws while
-- collision considers it absent, or the reverse.
--
-- It is not the player's movement authority and it never draws: `drawRecords`
-- returns presentation-neutral values for the renderer to consume.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldObjectActor = require("libs.engine.src.FieldObjectActor")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")

---@class FieldActorManager
---@field assets FieldActorAssetProvider
---@field variableSpriteRange { first: integer, last: integer }
---@field variableVarBase integer
---@field maps table<integer, table>
---@field eventState FieldEventState?
---@field unsubscribe fun()?
---@field pendingFlags table[]
local FieldActorManager = {}
FieldActorManager.__index = FieldActorManager

-- Raw event Y is a 1/16-unit fixed-point hint, matching the field event decoder.
local EVENT_Y_UNITS = 16

local SURFACE_ERROR_CODES = {
  TERRAIN_SURFACE_NOT_FOUND = "ACTOR_SURFACE_MISSING",
  TERRAIN_SURFACE_AMBIGUOUS = "ACTOR_SURFACE_AMBIGUOUS",
  TERRAIN_SURFACE_DISCONNECTED = "ACTOR_SURFACE_AMBIGUOUS",
}

---@class FieldActorManagerOptions
---@field assets FieldActorAssetProvider
---@field policy { variableSpriteRange: { first: integer, last: integer }, variableVarBase: integer }

-- opts.assets: a FieldActorAssetProvider-shaped acquire/release/knows owner.
-- opts.policy: { variableSpriteRange, variableVarBase } from
-- the field-actor manifest, so no decomp-derived constant is inlined here.
---@param opts FieldActorManagerOptions
---@return FieldActorManager
function FieldActorManager.new(opts)
  assert(type(opts) == "table" and opts.assets, "FieldActorManager requires an asset provider")
  local policy = opts.policy
  assert(
    type(policy) == "table" and policy.variableSpriteRange and policy.variableVarBase,
    "FieldActorManager requires a sprite policy"
  )
  return setmetatable({
    assets = opts.assets,
    variableSpriteRange = policy.variableSpriteRange,
    variableVarBase = policy.variableVarBase,
    maps = {},
    eventState = nil,
    unsubscribe = nil,
    pendingFlags = {},
  }, FieldActorManager)
end

local function occupancyKey(mapId, fieldX, fieldZ, surfaceId)
  return string.format("%d:%d:%d:%d", mapId, fieldX, fieldZ, surfaceId)
end

local function resolveSurface(runtimeMap, event, actorId)
  local ok, result = pcall(function()
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, event.x, event.z)
    -- Terrain is sampled at the tile centre, as the player and camera do.
    return SurfaceResolver.new(runtimeMap.terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = event.y / EVENT_Y_UNITS,
    })
  end)
  if ok then
    return result
  end
  if not Errors.is(result) then
    error(result)
  end
  local code = SURFACE_ERROR_CODES[result.code] or "ACTOR_SURFACE_MISSING"
  Errors.raise(
    code,
    "actor " .. actorId .. " has no single terrain surface: " .. result.message,
    { actorId = actorId, fieldX = event.x, fieldZ = event.z, sourceY = event.y, cause = result.code }
  )
end

-- The runtime sprite of an object event. FieldSystem_ResolveObjectSpriteID
-- redirects the variable range through the VAR_OBJ_* save variables before the
-- graphics lookup, once at object creation (pret/pokeheartgold src/map_object.c),
-- so this mirrors that call. The variables default to 0, the hero graphic, so a
-- variable actor exists even when no script has written one.
function FieldActorManager:_resolveSpriteId(event)
  local range = self.variableSpriteRange
  if event.spriteId < range.first or event.spriteId > range.last then
    return event.spriteId
  end
  assert(self.eventState, "variable sprite resolution requires an event state")
  return self.eventState:getVar(self.variableVarBase + (event.spriteId - range.first))
end

function FieldActorManager:_acquireVisual(spriteId, actorId)
  if not self.assets:knows(spriteId) then
    Errors.raise(
      "ACTOR_VISUAL_MISSING",
      "spriteId " .. spriteId .. " for " .. actorId .. " is not in the compiled actor set",
      { actorId = actorId, spriteId = spriteId }
    )
  end
  return self.assets:acquire(spriteId)
end

function FieldActorManager:_instantiate(entry, event)
  local runtimeMap = entry.runtimeMap
  local actorId = FieldObjectActor.actorId(runtimeMap.mapId, event.objectEventId)
  if entry.actors[actorId] then
    Errors.raise(
      "ACTOR_DUPLICATE_ID",
      "map " .. runtimeMap.mapId .. " declares object event " .. event.objectEventId .. " more than once",
      { actorId = actorId, mapId = runtimeMap.mapId, objectEventId = event.objectEventId }
    )
  end
  local surface = resolveSurface(runtimeMap, event, actorId)
  local world = FieldCoordinates.fieldToWorld(runtimeMap, event.x, event.z, surface.worldY)
  local spriteId = self:_resolveSpriteId(event)
  local asset = self:_acquireVisual(spriteId, actorId)

  local actor = FieldObjectActor.new({
    mapId = runtimeMap.mapId,
    sourceEvent = event,
    spriteId = spriteId,
    visualDef = asset.visual,
    fieldX = event.x,
    fieldZ = event.z,
    surfaceId = surface.surfaceId,
    worldX = world.x,
    worldY = world.y,
    worldZ = world.z,
  })
  actor.visualAsset = asset

  local key = occupancyKey(runtimeMap.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)
  local occupant = entry.occupancy[key]
  if actor.solid and occupant then
    self.assets:release(actor.spriteId)
    Errors.raise(
      "ACTOR_OCCUPANCY_CONFLICT",
      actorId .. " and " .. occupant.actorId .. " occupy the same field cell and surface",
      {
        actorId = actorId,
        otherActorId = occupant.actorId,
        mapId = runtimeMap.mapId,
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        surfaceId = actor.surfaceId,
      }
    )
  end
  if actor.solid then
    entry.occupancy[key] = actor
  end
  entry.actors[actorId] = actor
  entry.order[#entry.order + 1] = actor
  return actor
end

function FieldActorManager:_destroy(entry, actor)
  actor:clearFacingOverride()
  actor.visible = false
  entry.actors[actor.actorId] = nil
  entry.occupancy[occupancyKey(actor.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)] = nil
  for index, candidate in ipairs(entry.order) do
    if candidate == actor then
      table.remove(entry.order, index)
      break
    end
  end
  self.assets:release(actor.spriteId)
  actor.visualAsset, actor.visualDef = nil, nil
end

-- Idempotent for an already-active runtime map, so a transition's overlapping
-- load and commit phases cannot duplicate a map's actors.
function FieldActorManager:enterMap(runtimeMap, eventState)
  assert(runtimeMap and runtimeMap.fieldData, "enterMap requires a runtime map")
  assert(eventState, "enterMap requires a field event state")
  if self.eventState ~= eventState then
    if self.unsubscribe then
      self.unsubscribe()
    end
    self.eventState = eventState
    self.unsubscribe = eventState:subscribe(function(change)
      self:onEventStateChanged(change)
    end)
  end

  local existing = self.maps[runtimeMap.mapId]
  if existing then
    if existing.runtimeMap == runtimeMap then
      return
    end
    self:leaveMap(runtimeMap.mapId)
  end

  local entry = { runtimeMap = runtimeMap, actors = {}, order = {}, occupancy = {}, byFlag = {} }
  self.maps[runtimeMap.mapId] = entry
  local ok, err = pcall(function()
    for _, event in ipairs(runtimeMap.fieldData.events.objects or {}) do
      local flagged = entry.byFlag[event.eventFlag] or {}
      flagged[#flagged + 1] = event
      entry.byFlag[event.eventFlag] = flagged
      if not eventState:isFlagSet(event.eventFlag) then
        self:_instantiate(entry, event)
      end
    end
  end)
  if not ok then
    self:leaveMap(runtimeMap.mapId)
    error(err)
  end
end

function FieldActorManager:leaveMap(mapId)
  local entry = self.maps[mapId]
  if not entry then
    return
  end
  self.maps[mapId] = nil
  while #entry.order > 0 do
    self:_destroy(entry, entry.order[#entry.order])
  end
end

-- Queued rather than applied inline: a flag written mid-tick must not change
-- the world under code that has already consulted occupancy this tick.
function FieldActorManager:onEventStateChanged(change)
  if change.kind ~= "flag" then
    return
  end
  self.pendingFlags[#self.pendingFlags + 1] = change
end

function FieldActorManager:_applyFlag(change)
  for _, entry in pairs(self.maps) do
    for _, event in ipairs(entry.byFlag[change.id] or {}) do
      local actorId = FieldObjectActor.actorId(entry.runtimeMap.mapId, event.objectEventId)
      local actor = entry.actors[actorId]
      if change.newValue and actor then
        self:_destroy(entry, actor)
      elseif not change.newValue and not actor then
        self:_instantiate(entry, event)
      end
    end
  end
end

function FieldActorManager:step(tick)
  if self.eventState then
    self.eventState:setTick(tick)
  end
  local pending = self.pendingFlags
  if #pending > 0 then
    self.pendingFlags = {}
    for _, change in ipairs(pending) do
      self:_applyFlag(change)
    end
  end
  for _, entry in pairs(self.maps) do
    for _, actor in ipairs(entry.order) do
      actor.poseTick = actor.poseTick + 1
    end
  end
end

function FieldActorManager:drawRecords(alpha)
  local records = {}
  for _, entry in pairs(self.maps) do
    for _, actor in ipairs(entry.order) do
      records[#records + 1] = {
        actorId = actor.actorId,
        spriteId = actor.spriteId,
        visualDef = actor.visualDef,
        world = { x = actor.worldX, y = actor.worldY, z = actor.worldZ },
        facing = actor.facing,
        pose = actor.pose,
        poseTick = actor.poseTick,
        alpha = 1,
        visible = true,
        interpolation = alpha,
      }
    end
  end
  return records
end

function FieldActorManager:getById(actorId)
  for _, entry in pairs(self.maps) do
    local actor = entry.actors[actorId]
    if actor then
      return actor
    end
  end
  return nil
end

function FieldActorManager:getAt(mapId, fieldX, fieldZ, surfaceId)
  local entry = self.maps[mapId]
  return entry and entry.occupancy[occupancyKey(mapId, fieldX, fieldZ, surfaceId)] or nil
end

function FieldActorManager:isOccupied(mapId, fieldX, fieldZ, surfaceId, exceptActorId)
  local actor = self:getAt(mapId, fieldX, fieldZ, surfaceId)
  return actor ~= nil and actor.actorId ~= exceptActorId
end

function FieldActorManager:actorsOf(mapId)
  local entry = self.maps[mapId]
  return entry and entry.order or {}
end

-- --- Scripted actor API ------------------------------------------------------

-- Alias of `getById` for the script actor world contract.
function FieldActorManager:getActor(actorId)
  return self:getById(actorId)
end

function FieldActorManager:getPosition(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return nil
  end
  return { fieldX = actor.fieldX, fieldZ = actor.fieldZ, worldY = actor.worldY }
end

function FieldActorManager:getFacing(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return nil
  end
  return actor.facing
end

function FieldActorManager:setFacing(actorId, direction)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  actor:setFacing(direction)
end

-- Scripted position set: recomputes the world coordinates from the terrain
-- and rekeys the occupancy index so collision and the draw list never
-- disagree (the actor's surface is preserved; scripted movement stays on the
-- actor's current terrain surface).
function FieldActorManager:setPosition(actorId, position)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  local key = occupancyKey(actor.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)
  if entry.occupancy[key] == actor then
    entry.occupancy[key] = nil
  end
  local worldY = position.worldY or actor.worldY
  local world = FieldCoordinates.fieldToWorld(entry.runtimeMap, position.fieldX, position.fieldZ, worldY)
  actor:setPosition({
    fieldX = position.fieldX,
    fieldZ = position.fieldZ,
    worldY = world.y,
    worldX = world.x,
    worldZ = world.z,
  })
  if actor.solid then
    local newKey = occupancyKey(actor.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)
    entry.occupancy[newKey] = actor
  end
end

function FieldActorManager:show(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  actor:setVisible(true)
end

function FieldActorManager:hide(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  actor:setVisible(false)
end

function FieldActorManager:setMovementType(actorId, movementType)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  actor.scriptMovementType = movementType
end

-- Actors in this milestone have no autonomous movement engine, so a scripted
-- pause never waits on one; `lock_all` blocks only on outstanding scripted
-- movement tasks (the environment's movement generation).
function FieldActorManager:isBusy(actorId)
  return false
end

function FieldActorManager:canMove(actorId, direction)
  return self:getById(actorId) ~= nil
end

-- The numeric local map-object index of one actor (the pinned HGSS object
-- id), used by trigger comparisons.
function FieldActorManager:numericId(actorId)
  local actor = self:getById(actorId)
  return actor and actor.objectEventId or nil
end

function FieldActorManager:partnerId()
  return nil
end

function FieldActorManager:dispose()
  for mapId in pairs(self.maps) do
    self:leaveMap(mapId)
  end
  if self.unsubscribe then
    self.unsubscribe()
  end
  self.unsubscribe, self.eventState = nil, nil
  self.pendingFlags = {}
end

return FieldActorManager
