-- Owns the object actors of every runtime map the session currently holds, plus
-- the occupancy index they contribute to collision. Visibility follows
-- pret/pokeheartgold's rule that an object exists only while its event flag is
-- clear (`src/map_object.c`), so this manager subscribes to FieldEventState and
-- applies queued changes on one fixed-tick boundary: an actor never draws while
-- collision considers it absent, or the reverse.
--
-- It is not the player's movement authority and it never draws: `drawRecords`
-- returns presentation-neutral values for the renderer to consume.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldObjectActor = require("libs.engine.src.FieldObjectActor")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")

-- Pinned HGSS special object ids: the field camera target and the walking
-- partner (the object table pins these ids; see
-- pret/pokeheartgold src/field_system.c FieldSystem_CameraTarget).
local CAMERA_TARGET_OBJECT_ID = 241
local PARTNER_OBJECT_ID = 253

---@class FieldActorAssets
---@field knows fun(self: FieldActorAssets, spriteId: integer): boolean
---@field acquire fun(self: FieldActorAssets, spriteId: integer): table
---@field release fun(self: FieldActorAssets, spriteId: integer)

---@class FieldActorManager: ScriptActorManager
---@field assets FieldActorAssets
---@field variableSprites { first: integer, last: integer, variableBase: integer }
---@field variableVarBase integer
---@field maps table<integer, table>
---@field eventState FieldEventState?
---@field unsubscribe fun()?
---@field pendingFlags table[]
---@field currentMapId integer|nil
---@field _visualRevision integer
---@field _drawRecords table[]
---@field _drawRecordByActorId table<string, table>
local FieldActorManager = {}
FieldActorManager.__index = FieldActorManager

-- Raw event Y is a 1/16-unit fixed-point hint, matching the field event decoder.
local EVENT_Y_UNITS = 16

-- The terrain-surface failure codes an actor construction can recover from,
-- mapped to the actor-scoped codes the script world observes. A structured
-- error of any other kind propagates unchanged rather than being re-labelled.
local SURFACE_ERROR_CODES = {
  [FieldErrors.TERRAIN_SURFACE_NOT_FOUND] = FieldErrors.ACTOR_SURFACE_MISSING,
  [FieldErrors.TERRAIN_SURFACE_AMBIGUOUS] = FieldErrors.ACTOR_SURFACE_AMBIGUOUS,
  [FieldErrors.TERRAIN_SURFACE_DISCONNECTED] = FieldErrors.ACTOR_SURFACE_AMBIGUOUS,
}

---@class FieldActorManagerOptions
---@field assets FieldActorAssets
---@field policy { variableSprites: { first: integer, last: integer, variableBase: integer } }

-- opts.assets: a FieldActorAssetProvider-shaped acquire/release/knows owner.
-- opts.policy: the generated actor index's runtime block
-- ({ variableSprites = { first, last, variableBase } }), so no decomp-derived
-- constant is inlined here.
---@param opts FieldActorManagerOptions
---@return FieldActorManager
function FieldActorManager.new(opts)
  assert(type(opts) == "table" and opts.assets, "FieldActorManager requires an asset provider")
  local policy = opts.policy
  assert(type(policy) == "table" and policy.variableSprites, "FieldActorManager requires a variable-sprite policy")
  local variableSprites = policy.variableSprites
  return setmetatable({
    assets = opts.assets,
    variableSprites = variableSprites,
    variableVarBase = variableSprites.variableBase,
    maps = {},
    eventState = nil,
    unsubscribe = nil,
    pendingFlags = {},
    currentMapId = nil,
    _visualRevision = 0,
    _drawRecords = {},
    _drawRecordByActorId = {},
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
  -- Only expected surface-resolution conditions are actor-surface failures; a
  -- structured error of any other kind (e.g. out-of-coverage coordinates)
  -- propagates unchanged rather than being re-labelled as a missing surface.
  local code = SURFACE_ERROR_CODES[result.code]
  if not code then
    error(result)
  end
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
  local sprites = self.variableSprites
  if event.spriteId < sprites.first or event.spriteId > sprites.last then
    return event.spriteId
  end
  assert(self.eventState, "variable sprite resolution requires an event state")
  return self.eventState:getVar(self.variableVarBase + (event.spriteId - sprites.first))
end

function FieldActorManager:_acquireVisual(spriteId, actorId)
  if not self.assets:knows(spriteId) then
    Errors.raise(
      FieldErrors.ACTOR_VISUAL_MISSING,
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
      FieldErrors.ACTOR_DUPLICATE_ID,
      "map " .. runtimeMap.mapId .. " declares object event " .. event.objectEventId .. " more than once",
      { actorId = actorId, mapId = runtimeMap.mapId, objectEventId = event.objectEventId }
    )
  end
  local surface = resolveSurface(runtimeMap, event, actorId)
  local world = FieldCoordinates.fieldToWorld(runtimeMap, event.x, event.z, surface.worldY)
  local spriteId = self:_resolveSpriteId(event)
  local asset = self:_acquireVisual(spriteId, actorId)

  -- Local ownership: the visual is acquired for this construction only, so any
  -- failure between acquisition and completed insertion releases it before the
  -- error propagates. Solid actors (the default; an event may opt out) take the
  -- occupancy cell, and two solid actors on one cell are a conflict.
  local actor
  local ok, err = pcall(function()
    actor = FieldObjectActor.new({
      mapId = runtimeMap.mapId,
      sourceEvent = event,
      spriteId = spriteId,
      solid = event.solid ~= false,
      fieldX = event.x,
      fieldZ = event.z,
      surfaceId = surface.surfaceId,
      worldX = world.x,
      worldY = world.y,
      worldZ = world.z,
    })

    local key = occupancyKey(runtimeMap.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)
    local occupant = entry.occupancy[key]
    if actor.solid and occupant then
      Errors.raise(
        FieldErrors.ACTOR_OCCUPANCY_CONFLICT,
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
    entry.byIndex[actor.objectEventId] = actorId
    entry.order[#entry.order + 1] = actor
    self._visualRevision = self._visualRevision + 1
  end)
  if not ok then
    self.assets:release(spriteId)
    error(err)
  end
  return actor
end

function FieldActorManager:_destroy(entry, actor)
  actor:clearFacingOverride()
  entry.actors[actor.actorId] = nil
  entry.byIndex[actor.objectEventId] = nil
  -- Only solid actors ever occupy a cell, and only the exact occupant may
  -- vacate it: a non-solid or stale actor must never erase another actor's
  -- occupancy entry by coordinate.
  local key = occupancyKey(actor.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)
  if actor.solid and entry.occupancy[key] == actor then
    entry.occupancy[key] = nil
  end
  for index, candidate in ipairs(entry.order) do
    if candidate == actor then
      table.remove(entry.order, index)
      break
    end
  end
  self.assets:release(actor.spriteId)
  self._drawRecordByActorId[actor.actorId] = nil
  self._visualRevision = self._visualRevision + 1
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

  local entry = { runtimeMap = runtimeMap, actors = {}, order = {}, occupancy = {}, byFlag = {}, byIndex = {} }
  self.maps[runtimeMap.mapId] = entry
  self.currentMapId = runtimeMap.mapId
  local ok, err = pcall(function()
    -- The map loader validates the four event collections against the
    -- authoritative field-record rule, so a runtime map always carries the
    -- objects array; a missing collection here is a composition fault, never
    -- an empty map. The failure rolls the entry back like any construction
    -- failure.
    local objects = runtimeMap.fieldData.events.objects
    assert(type(objects) == "table", "enterMap requires the compiled object collection")
    for _, event in ipairs(objects) do
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
  if self.currentMapId == mapId then
    self.currentMapId = nil
  end
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

function FieldActorManager:syncEventStateChanges()
  local pending = self.pendingFlags
  if #pending == 0 then
    return
  end
  self.pendingFlags = {}
  for _, change in ipairs(pending) do
    self:_applyFlag(change)
  end
end

function FieldActorManager:step(tick)
  if self.eventState then
    self.eventState:setTick(tick)
  end
  self:syncEventStateChanges()
  for _, entry in pairs(self.maps) do
    for _, actor in ipairs(entry.order) do
      if actor:isScriptedMoving() then
        -- poseTick is driven by scripted advancement; the manager does not double-advance.
      elseif not actor.animationPaused then
        actor.poseTick = actor.poseTick + 1
      end
    end
  end
end

-- Monotonic signal for presentation residency. Movement, facing, pose, and
-- visibility changes do not alter the set of sprite definitions the field
-- presentation must hold.
---@return integer
function FieldActorManager:visualRevision()
  return self._visualRevision
end

-- Add the distinct sprite definitions needed by every live actor to `out`.
-- The caller owns clearing a reused set before collecting a new snapshot.
---@param out table<integer, boolean>
function FieldActorManager:collectSpriteIds(out)
  assert(type(out) == "table", "collectSpriteIds requires a set table")
  for _, entry in pairs(self.maps) do
    for _, actor in ipairs(entry.order) do
      out[actor.spriteId] = true
    end
  end
end

function FieldActorManager:drawRecords()
  local records = self._drawRecords
  local count = 0
  for _, entry in pairs(self.maps) do
    for _, actor in ipairs(entry.order) do
      count = count + 1
      local record = self._drawRecordByActorId[actor.actorId]
      if not record then
        record = { world = {} }
        self._drawRecordByActorId[actor.actorId] = record
      end
      -- Render-only presentation offset (e.g. walk-in-place bob) is applied
      -- here, at the final draw-position boundary; the actor's logical
      -- worldX/worldY/worldZ (read by terrain, collision, and save) never
      -- carry it. A fake actor without the field draws at zero offset.
      local offset = actor.presentationOffset
      record.actorId = actor.actorId
      record.spriteId = actor.spriteId
      record.world.x = actor.worldX + (offset and offset.x or 0)
      record.world.y = actor.worldY + (offset and offset.y or 0)
      record.world.z = actor.worldZ
      record.facing = actor.facing
      record.pose = actor.pose
      record.poseTick = actor.poseTick
      record.activeEmoteKind = actor.activeEmoteKind
      record.visible = actor.visible
      records[count] = record
    end
  end
  for index = #records, count + 1, -1 do
    records[index] = nil
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

-- Position set: resolves the destination surface from the terrain (an
-- explicit worldY selects the plate at that height; otherwise the actor's
-- current surface is preserved whenever it covers the destination), then
-- rekeys the occupancy index so collision and the draw list never disagree.
-- The whole destination is calculated and validated -- coordinates and
-- surface -- before the actor or the occupancy index is mutated, so a
-- conversion or surface failure leaves the actor exactly where it was.
--
-- The hard occupancy-conflict check (the same invariant _instantiate
-- enforces) applies here too, with one narrowing: pinned HGSS source never
-- performs an inter-object collision check while a script's `ApplyMovement`
-- repositions an actor -- only autonomous walk-AI and player movement check
-- it. `options.scripted` is how a script-driven caller (currently only
-- `ScriptActorWorld`) identifies itself; every other caller keeps the
-- default strict behavior, including two script-driven actors that briefly
-- land on the same cell mid-sequence: the later `setPosition` call simply
-- takes over the occupancy slot instead of raising.
---@param options { scripted?: boolean }?
function FieldActorManager:setPosition(actorId, position, options)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  local localX, localZ = FieldCoordinates.fieldToLocal(entry.runtimeMap, position.fieldX, position.fieldZ)
  local surfaceOpts = {
    localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
    localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    currentY = position.worldY or actor.worldY,
  }
  if position.worldY == nil then
    surfaceOpts.currentSurfaceId = actor.surfaceId
  end
  local sample = SurfaceResolver.new(entry.runtimeMap.terrain):resolve(surfaceOpts)
  local world = FieldCoordinates.fieldToWorld(entry.runtimeMap, position.fieldX, position.fieldZ, sample.worldY)
  local newKey = occupancyKey(actor.mapId, position.fieldX, position.fieldZ, sample.surfaceId)
  local scripted = options ~= nil and options.scripted == true
  if actor.solid then
    local occupant = entry.occupancy[newKey]
    if occupant ~= nil and occupant ~= actor and not scripted then
      Errors.raise(
        FieldErrors.ACTOR_OCCUPANCY_CONFLICT,
        actorId .. " cannot move onto " .. occupant.actorId .. "'s field cell",
        {
          actorId = actorId,
          otherActorId = occupant.actorId,
          mapId = actor.mapId,
          fieldX = position.fieldX,
          fieldZ = position.fieldZ,
          surfaceId = sample.surfaceId,
        }
      )
    end
    local oldKey = occupancyKey(actor.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)
    if entry.occupancy[oldKey] == actor then
      entry.occupancy[oldKey] = nil
    end
    entry.occupancy[newKey] = actor
  end
  actor:setPosition({
    fieldX = position.fieldX,
    fieldZ = position.fieldZ,
    worldY = sample.worldY,
    worldX = world.x,
    worldZ = world.z,
    surfaceId = sample.surfaceId,
  })
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

-- Scripted pause_animation/resume_animation: the actor's pose clock stops
-- advancing while paused (the manager's fixed-tick step honors the flag).
---@param actorId string
---@param paused boolean
function FieldActorManager:setAnimationPaused(actorId, paused)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  actor.animationPaused = paused == true
end

-- --- Scripted motion presentation (manager owns occupancy/terrain) -------

-- Resolve destination for a scripted action without mutating actor or occupancy.
-- Returns start/dest world anchors.
function FieldActorManager:_resolveScriptedDestination(actor, direction, distance)
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  local deltaMap = {
    north = { fieldX = 0, fieldZ = -1 },
    south = { fieldX = 0, fieldZ = 1 },
    west = { fieldX = -1, fieldZ = 0 },
    east = { fieldX = 1, fieldZ = 0 },
  }
  local startFieldX, startFieldZ = actor.fieldX, actor.fieldZ
  local startWorldX, startWorldY, startWorldZ = actor.worldX, actor.worldY, actor.worldZ
  local destFieldX, destFieldZ = startFieldX, startFieldZ
  local destWorldX, destWorldY, destWorldZ = startWorldX, startWorldY, startWorldZ
  local destSurfaceId = actor.surfaceId
  if direction ~= nil and distance ~= "zero" then
    local delta = assert(deltaMap[direction], "unknown direction " .. tostring(direction))
    destFieldX = startFieldX + delta.fieldX
    destFieldZ = startFieldZ + delta.fieldZ
    -- Resolve surface at destination center.
    local localX, localZ = FieldCoordinates.fieldToLocal(entry.runtimeMap, destFieldX, destFieldZ)
    local sample = SurfaceResolver.new(entry.runtimeMap.terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = actor.worldY,
      currentSurfaceId = actor.surfaceId,
    })
    local world = FieldCoordinates.fieldToWorld(entry.runtimeMap, destFieldX, destFieldZ, sample.worldY)
    destWorldX, destWorldY, destWorldZ = world.x, world.y, world.z
    destSurfaceId = sample.surfaceId
  elseif direction ~= nil and distance == "zero" then
    -- zero jump stays on same tile; no surface change.
    destFieldX, destFieldZ = startFieldX, startFieldZ
    destWorldX, destWorldY, destWorldZ = startWorldX, startWorldY, startWorldZ
    destSurfaceId = actor.surfaceId
  end
  return {
    start = {
      fieldX = startFieldX,
      fieldZ = startFieldZ,
      worldX = startWorldX,
      worldY = startWorldY,
      worldZ = startWorldZ,
      surfaceId = actor.surfaceId,
    },
    dest = {
      fieldX = destFieldX,
      fieldZ = destFieldZ,
      worldX = destWorldX,
      worldY = destWorldY,
      worldZ = destWorldZ,
      surfaceId = destSurfaceId,
    },
  }
end

function FieldActorManager:beginScriptedAction(actorId, action)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  local kind = action.action
  -- Face is instantaneous: apply the facing directly, then still flow
  -- through the generic actor transaction below (with a stay-put start/dest)
  -- so pose settles to idle and any residual locomotion presentation offset
  -- clears exactly like every other non-locomotion action.
  if kind == "face" and action.direction ~= nil then
    actor:setFacing(action.direction)
  end
  local direction = action.direction
  local distance = action.distance
  local speed = action.speed
  local durationTicks
  if
    kind == "walk"
    or kind == "walk_in_place"
    or kind == "jump"
    or kind == "face"
    or kind == "delay"
    or kind == "emote"
    or kind == "gesture"
  then
    local MovementCalibration = require("libs.engine.src.script.tasks.MovementCalibration")
    durationTicks = MovementCalibration.actionTicks(action)
  else
    Errors.raise(
      ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE,
      "unsupported scripted action " .. tostring(kind),
      { actor = actorId }
    )
  end
  local destInfo
  if kind == "walk" then
    destInfo = self:_resolveScriptedDestination(actor, direction, "near")
    -- For walk, treat as one-tile displacement.
    -- distance param not used; use direction delta.
  elseif kind == "jump" then
    destInfo = self:_resolveScriptedDestination(actor, direction, distance)
  elseif kind == "walk_in_place" or kind == "face" or kind == "delay" or kind == "emote" or kind == "gesture" then
    destInfo = {
      start = {
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        worldX = actor.worldX,
        worldY = actor.worldY,
        worldZ = actor.worldZ,
        surfaceId = actor.surfaceId,
      },
      dest = {
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        worldX = actor.worldX,
        worldY = actor.worldY,
        worldZ = actor.worldZ,
        surfaceId = actor.surfaceId,
      },
    }
  end
  actor:beginScriptedAction({
    action = kind,
    direction = direction,
    distance = distance,
    speed = speed,
    start = destInfo.start,
    dest = destInfo.dest,
    durationTicks = durationTicks,
    -- The decoded semantic emote kind (e.g. "exclamation"); only meaningful
    -- when kind == "emote".
    name = action.name,
  })
end

function FieldActorManager:advanceScriptedAction(actorId, progressTicks, durationTicks)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  actor:advanceScriptedAction(progressTicks, durationTicks)
end

function FieldActorManager:commitScriptedAction(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  local m = actor:scriptedMotionState()
  if not m then
    return
  end
  -- Only walk/jump change occupancy; walk_in_place/face never.
  if m.action == "walk" or m.action == "jump" then
    if m.destFieldX ~= m.startFieldX or m.destFieldZ ~= m.startFieldZ or m.destSurfaceId ~= m.startSurfaceId then
      local entry = assert(self.maps[actor.mapId], "actor map entry missing")
      if actor.solid then
        local newKey = occupancyKey(actor.mapId, m.destFieldX, m.destFieldZ, m.destSurfaceId)
        local oldKey = occupancyKey(actor.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)
        if entry.occupancy[oldKey] == actor then
          entry.occupancy[oldKey] = nil
        end
        -- Scripted movement bypasses inter-object collision check: takes over slot.
        entry.occupancy[newKey] = actor
      end
    end
  end
  actor:commitScriptedAction()
end

function FieldActorManager:cancelScriptedMovement(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return
  end
  if actor:isScriptedMoving() then
    actor:cancelScriptedAction()
  else
    -- Also settle any fractional world drift: recompute world from committed tile.
    local entry = self.maps[actor.mapId]
    if entry then
      local world = FieldCoordinates.fieldToWorld(entry.runtimeMap, actor.fieldX, actor.fieldZ, actor.worldY)
      actor.worldX = world.x
      actor.worldZ = world.z
      -- worldY stays as committed surface height; actor.worldY already correct.
    end
  end
end

-- Called once a movement plan is fully exhausted, when there is no further
-- action to begin (the usual locomotion-to-idle settle point). Guarantees
-- the actor never keeps its final action's presentation after the task ends.
function FieldActorManager:settleScriptedAction(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  actor:settlePresentation()
end

function FieldActorManager:isScriptedMoving(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return false
  end
  return actor:isScriptedMoving()
end

-- The numeric local map-object index of one actor (the pinned HGSS object
-- id), used by trigger comparisons.
function FieldActorManager:numericId(actorId)
  local actor = self:getById(actorId)
  return actor and actor.objectEventId or nil
end

-- Resolve a numeric local map-object index to the current map's actor id
-- (the pinned HGSS object-id path used by `S.actorIndex(n)`); nil when the
-- current map has no such object.
---@param index integer
---@return string|nil
function FieldActorManager:actorIdForMapIndex(index)
  local entry = self.currentMapId ~= nil and self.maps[self.currentMapId] or nil
  return entry and entry.byIndex[index] or nil
end

-- The field camera target (pinned HGSS object id 241) of the current map;
-- nil when the map declares no camera target.
---@return string|nil
function FieldActorManager:cameraTargetId()
  return self:actorIdForMapIndex(CAMERA_TARGET_OBJECT_ID)
end

-- The walking partner (pinned HGSS object id 253) of the current map; nil
-- while no Pokémon follows the player.
---@return string|nil
function FieldActorManager:partnerId()
  return self:actorIdForMapIndex(PARTNER_OBJECT_ID)
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
