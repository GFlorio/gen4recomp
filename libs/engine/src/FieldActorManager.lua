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
---@field acquire fun(self: FieldActorAssets, spriteId: integer): FieldActorAsset
---@field release fun(self: FieldActorAssets, spriteId: integer)

---@class FieldActorAsset
---@field spriteId integer
---@field visual table
---@field references integer
-- The provider owns the acquired visual; the manager only holds its reference
-- through the provider's acquire/release pair.

---@class FieldActorManager.VariableSprites
---@field first integer
---@field last integer
---@field variableBase integer

---@class FieldActorEvent
---@field index integer
---@field objectEventId integer
---@field spriteId integer
---@field movement integer
---@field type integer
---@field eventFlag integer
---@field scriptId integer
---@field facingDirectionRaw integer
---@field facingDirection string
---@field x integer
---@field z integer
---@field y integer
---@field solid boolean?

---@class FieldActorEventCollections
---@field objects FieldActorEvent[]

---@class FieldActorFieldData
---@field events FieldActorEventCollections

---@class FieldActorSurfaceSample
---@field surfaceId integer
---@field worldY number

---@class FieldActorSurfaceOptions
---@field localX number
---@field localZ number
---@field currentY number
---@field currentSurfaceId integer?

---@class FieldActorStateChange
---@field kind "flag"|"var"
---@field id integer
---@field oldValue boolean|integer
---@field newValue boolean|integer
---@field tick integer

---@class FieldActorFlagChange: FieldActorStateChange
---@field kind "flag"
---@field oldValue boolean
---@field newValue boolean

---@class FieldActorManager
---@field assets FieldActorAssets
---@field variableSprites FieldActorManager.VariableSprites
---@field variableVarBase integer
---@field maps table<integer, FieldActorManager.Entry>
---@field eventState FieldEventState?
---@field unsubscribe fun()?
---@field pendingFlags FieldActorFlagChange[]
---@field currentMapId integer|nil
---@field _visualRevision integer
---@field _drawRecords FieldActorManager.DrawRecord[]
---@field _drawRecordByActorId table<string, FieldActorManager.DrawRecord>
---@field step fun(self: FieldActorManager, tick: integer)
---@field _resolveSpriteId fun(self: FieldActorManager, event: FieldActorEvent, eventState: FieldEventState?): integer
---@field _acquireVisual fun(self: FieldActorManager, spriteId: integer, actorId: string): FieldActorAsset
---@field _instantiate fun(self: FieldActorManager, entry: FieldActorManager.Entry, event: FieldActorEvent, eventState: FieldEventState?): FieldActorManager.Actor
---@field _destroy fun(self: FieldActorManager, entry: FieldActorManager.Entry, actor: FieldActorManager.Actor)
---@field leaveMap fun(self: FieldActorManager, mapId: integer)
---@field prepareMap fun(self: FieldActorManager, runtimeMap: RuntimeFieldMap, eventState: FieldEventState): FieldActorManager.PreparedMap
---@field commitPrepared fun(self: FieldActorManager, prepared: FieldActorManager.PreparedMap, sourceMapId: integer)
---@field discardPrepared fun(self: FieldActorManager, prepared: FieldActorManager.PreparedMap)
---@field enterMap fun(self: FieldActorManager, runtimeMap: RuntimeFieldMap, eventState: FieldEventState)
---@field dispose fun(self: FieldActorManager)
---@field visualRevision fun(self: FieldActorManager): integer
---@field collectSpriteIds fun(self: FieldActorManager, out: table<integer, boolean>)
---@field drawRecords fun(self: FieldActorManager): FieldActorManager.DrawRecord[]
---@field reconcilePhysicalWorld fun(self: FieldActorManager)
---@field isOccupied fun(self: FieldActorManager, mapId: integer, fieldX: integer, fieldZ: integer, surfaceId: integer, exceptActorId: string?): boolean
---@field onEventStateChanged fun(self: FieldActorManager, change: FieldActorStateChange)
---@field _applyFlag fun(self: FieldActorManager, change: FieldActorFlagChange)
---@field getById fun(self: FieldActorManager, actorId: string): FieldActorManager.Actor?
---@field getAt fun(self: FieldActorManager, mapId: integer, fieldX: integer, fieldZ: integer, surfaceId: integer): FieldActorManager.Actor?
---@field probeAt fun(self: FieldActorManager, runtimeMap: RuntimeFieldMap, eventState: FieldEventState, fieldX: integer, fieldZ: integer, surfaceId: integer): FieldActorManager.ProbeResult?
---@field actorIdForMapIndex fun(self: FieldActorManager, index: integer): string?
---@class FieldActorManager.Actor: FieldObjectActor
---@field scriptMovementType string?
---@field animationPaused boolean?

---@class FieldActorManager.Entry
---@field runtimeMap RuntimeFieldMap
---@field actors table<string, FieldActorManager.Actor>
---@field order FieldActorManager.Actor[]
---@field occupancy table<string, FieldActorManager.Actor>
---@field byFlag table<integer, FieldActorEvent[]>
---@field byIndex table<integer, string>

---@class FieldActorManager.PreparedMap
---@field entry FieldActorManager.Entry
---@field eventState FieldEventState
---@field state "prepared"|"committed"|"discarded"

---@class FieldActorManager.Position
---@field fieldX integer
---@field fieldZ integer
---@field worldY number?

---@class FieldActorManager.ActorPosition
---@field fieldX integer
---@field fieldZ integer
---@field worldY number?

---@class FieldActorManager.DrawRecord
---@field actorId string
---@field spriteId integer
---@field world { x: number, y: number, z: number }
---@field facing FieldDirection
---@field pose string
---@field poseTick integer
---@field visible boolean
---@class FieldActorManager.ProbeResult
---@field actorId string
---@field objectEventId integer
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
---@field policy { variableSprites: FieldActorManager.VariableSprites }

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
  ---@cast variableSprites FieldActorManager.VariableSprites
  local manager = setmetatable({
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
  ---@cast manager FieldActorManager
  return manager
end

---@param mapId integer
---@param fieldX integer
---@param fieldZ integer
---@param surfaceId integer
---@return string
local function occupancyKey(mapId, fieldX, fieldZ, surfaceId)
  assert(surfaceId ~= nil, "resident actor surface id is required")
  return string.format("%d:%d:%d:%d", mapId, fieldX, fieldZ, surfaceId)
end

local function cellKeyFor(fieldX, fieldZ)
  return string.format("%d:%d", math.floor(fieldX / 32), math.floor(fieldZ / 32))
end

local function isResident(runtimeMap, fieldX, fieldZ)
  return not runtimeMap.coverage or runtimeMap.coverage:containsGlobal(fieldX, fieldZ)
end

---@param runtimeMap RuntimeFieldMap
---@param fieldX integer
---@param fieldZ integer
---@param sourceY number
---@param actorId string
---@return FieldActorSurfaceSample
local function resolveSurfaceAt(runtimeMap, fieldX, fieldZ, sourceY, actorId)
  local ok, result = pcall(function()
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
    -- Terrain is sampled at the tile centre, as the player and camera do.
    local surfaceOptions = {
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = sourceY / EVENT_Y_UNITS,
    } ---@type FieldActorSurfaceOptions
    return SurfaceResolver.new(runtimeMap.terrain):resolve(surfaceOptions) --[[@as FieldActorSurfaceSample]]
  end)
  if ok then
    return result --[[@as FieldActorSurfaceSample]]
  end
  if not Errors.is(result) then
    error(result)
  end
  -- Only expected surface-resolution conditions are actor-surface failures; a
  -- structured error of any other kind (e.g. out-of-coverage coordinates)
  -- propagates unchanged rather than being re-labelled as a missing surface.
  local structuredError = result --[[@as Errors.Error]]
  local code = SURFACE_ERROR_CODES[structuredError.code]
  if not code then
    error(structuredError)
  end
  Errors.raise(
    code,
    "actor " .. actorId .. " has no single terrain surface: " .. structuredError.message,
    { actorId = actorId, fieldX = fieldX, fieldZ = fieldZ, sourceY = sourceY, cause = structuredError.code }
  )
  error("unreachable after actor surface error")
end

local function resolveSurface(runtimeMap, event, actorId)
  return resolveSurfaceAt(runtimeMap, event.x, event.z, event.y, actorId)
end

local function projectionFor(runtimeMap, actor)
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, actor.fieldX, actor.fieldZ)
  local centerX, centerZ = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local surfaceId = actor.surfaceId
  if actor.cellKey and actor.sourceSurfaceId and runtimeMap.fieldRegion and runtimeMap.fieldRegion.sourceSurface then
    surfaceId = assert(
      runtimeMap.fieldRegion:sourceSurface(actor.cellKey, actor.sourceSurfaceId),
      "actor source surface is absent from coverage"
    )
  end
  if surfaceId == nil or not runtimeMap.terrain:contains(surfaceId, centerX, centerZ) then
    local sample = resolveSurfaceAt(runtimeMap, actor.fieldX, actor.fieldZ, actor.sourceEvent.y, actor.actorId)
    surfaceId = sample.surfaceId
  end
  local plate = assert(runtimeMap.terrain:plate(surfaceId), "actor projected surface is missing")
  local worldY = runtimeMap.terrain:sampleHeight(surfaceId, centerX, centerZ)
  local world = FieldCoordinates.fieldToWorld(runtimeMap, actor.fieldX, actor.fieldZ, worldY)
  return {
    surfaceId = surfaceId,
    cellKey = actor.cellKey or plate.cellKey or cellKeyFor(actor.fieldX, actor.fieldZ),
    sourceSurfaceId = actor.sourceSurfaceId or plate.sourceSurfaceId or surfaceId,
    worldX = world.x,
    worldY = world.y,
    worldZ = world.z,
  }
end

-- The runtime sprite of an object event. FieldSystem_ResolveObjectSpriteID
-- redirects the variable range through the VAR_OBJ_* save variables before the
-- graphics lookup, once at object creation (pret/pokeheartgold src/map_object.c),
-- so this mirrors that call. The variables default to 0, the hero graphic, so a
-- variable actor exists even when no script has written one.
---@param event FieldActorEvent
---@param eventState FieldEventState?
---@return integer
---@param self FieldActorManager
function FieldActorManager:_resolveSpriteId(event, eventState)
  local sprites = self.variableSprites
  if event.spriteId < sprites.first or event.spriteId > sprites.last then
    return event.spriteId
  end
  local state = eventState or self.eventState
  assert(state, "variable sprite resolution requires an event state")
  return state:getVar(self.variableVarBase + (event.spriteId - sprites.first))
end

---@param self FieldActorManager
---@param spriteId integer
---@param actorId string
---@return FieldActorAsset
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

---@param self FieldActorManager
---@param entry FieldActorManager.Entry
---@param event FieldActorEvent
---@param eventState FieldEventState?
---@return FieldActorManager.Actor
function FieldActorManager:_instantiate(entry, event, eventState)
  local runtimeMap = entry.runtimeMap
  local actorId = FieldObjectActor.actorId(runtimeMap.mapId, event.objectEventId)
  if entry.actors[actorId] then
    Errors.raise(
      FieldErrors.ACTOR_DUPLICATE_ID,
      "map " .. runtimeMap.mapId .. " declares object event " .. event.objectEventId .. " more than once",
      { actorId = actorId, mapId = runtimeMap.mapId, objectEventId = event.objectEventId }
    )
  end
  local resident = isResident(runtimeMap, event.x, event.z)
  local surface = resident and resolveSurface(runtimeMap, event, actorId) or nil
  local world = surface and FieldCoordinates.fieldToWorld(runtimeMap, event.x, event.z, surface.worldY) or nil
  local plate = surface and runtimeMap.terrain:plate(surface.surfaceId) or nil
  local spriteId = self:_resolveSpriteId(event, eventState)
  self:_acquireVisual(spriteId, actorId)

  -- Local ownership: the visual is acquired for this construction only, so any
  -- failure between acquisition and completed insertion releases it before the
  -- error propagates. Solid actors (the default; an event may opt out) take the
  -- occupancy cell, and two solid actors on one cell are a conflict.
  local actor ---@type FieldActorManager.Actor
  local ok, err = pcall(function()
    actor = FieldObjectActor.new({
      mapId = runtimeMap.mapId,
      sourceEvent = event,
      spriteId = spriteId,
      solid = event.solid,
      fieldX = event.x,
      fieldZ = event.z,
      cellKey = plate and plate.cellKey or (resident and cellKeyFor(event.x, event.z) or nil),
      sourceSurfaceId = plate and plate.sourceSurfaceId or nil,
      surfaceId = surface and surface.surfaceId or nil,
      worldX = world and world.x or nil,
      worldY = world and world.y or nil,
      worldZ = world and world.z or nil,
      resident = resident,
    }) --[[@as FieldActorManager.Actor]]

    if actor.resident then
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

---@param entry FieldActorManager.Entry
---@param actor FieldActorManager.Actor
---@param self FieldActorManager
function FieldActorManager:_destroy(entry, actor)
  actor:clearFacingOverride()
  entry.actors[actor.actorId] = nil
  entry.byIndex[actor.objectEventId] = nil
  -- Only solid actors ever occupy a cell, and only the exact occupant may
  -- vacate it: a non-solid or stale actor must never erase another actor's
  -- occupancy entry by coordinate.
  if actor.resident then
    local key = occupancyKey(actor.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)
    if actor.solid and entry.occupancy[key] == actor then
      entry.occupancy[key] = nil
    end
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

---@param manager FieldActorManager
---@param actorId string
---@return FieldActorManager.Actor
local function requireActor(manager, actorId)
  local actor = manager:getById(actorId)
  if actor ~= nil then
    return actor
  end
  Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  error("unreachable: actor lookup failure was raised")
end

---@param self FieldActorManager
---@param eventState FieldEventState
local function bindEventState(self, eventState)
  if self.eventState ~= eventState then
    local oldUnsubscribe = self.unsubscribe
    local unsubscribe = eventState:subscribe(function(change)
      local stateChange = change --[[@as FieldActorStateChange]]
      self:onEventStateChanged(stateChange)
    end)
    self.eventState = eventState
    self.unsubscribe = unsubscribe
    if oldUnsubscribe then
      oldUnsubscribe()
    end
  end
end

---@param runtimeMap RuntimeFieldMap
---@return FieldActorManager.Entry
local function newEntry(runtimeMap)
  return {
    runtimeMap = runtimeMap,
    actors = {},
    order = {},
    occupancy = {},
    byFlag = {},
    byIndex = {},
  } ---@type FieldActorManager.Entry
end

---@param self FieldActorManager
---@param entry FieldActorManager.Entry
---@param eventState FieldEventState
local function populateEntry(self, entry, eventState)
  local runtimeMap = entry.runtimeMap
  local ok, err = pcall(function()
    -- The map loader validates the four event collections against the
    -- authoritative field-record rule, so a runtime map always carries the
    -- objects array; a missing collection here is a composition fault, never
    -- an empty map. The failure rolls the entry back like any construction
    -- failure.
    local fieldData = runtimeMap.fieldData --[[@as FieldActorFieldData]]
    local objects = fieldData.events.objects ---@type FieldActorEvent[]
    assert(type(objects) == "table", "enterMap requires the compiled object collection")
    for _, event in ipairs(objects) do
      local flagged = entry.byFlag[event.eventFlag] or {}
      flagged[#flagged + 1] = event
      entry.byFlag[event.eventFlag] = flagged
      if not eventState:isFlagSet(event.eventFlag) then
        self:_instantiate(entry, event, eventState)
      end
    end
  end)
  if not ok then
    while #entry.order > 0 do
      self:_destroy(entry, entry.order[#entry.order])
    end
    error(err)
  end
end

-- Builds all destination actors in an unattached entry. The live map index,
-- event subscription, and current-map identity remain untouched until commit.
---@param runtimeMap RuntimeFieldMap
---@param eventState FieldEventState
---@param self FieldActorManager
---@return FieldActorManager.PreparedMap
function FieldActorManager:prepareMap(runtimeMap, eventState)
  assert(runtimeMap and runtimeMap.fieldData, "prepareMap requires a runtime map")
  assert(eventState, "prepareMap requires a field event state")
  assert(not self.maps[runtimeMap.mapId], "cannot prepare an already-live map")
  local entry = newEntry(runtimeMap)
  populateEntry(self, entry, eventState)
  return {
    entry = entry,
    eventState = eventState,
    state = "prepared",
  } ---@type FieldActorManager.PreparedMap
end

---@param prepared FieldActorManager.PreparedMap
---@param self FieldActorManager
function FieldActorManager:discardPrepared(prepared)
  assert(prepared and prepared.state == "prepared", "prepared map is not disposable")
  while #prepared.entry.order > 0 do
    self:_destroy(prepared.entry, prepared.entry.order[#prepared.entry.order])
  end
  prepared.state = "discarded"
end

-- Publishes the prepared destination, then removes the source. Failures after
-- this boundary are intentionally surfaced to the caller; the destination is
-- already the live actor world and is not rolled back by this manager.
---@param prepared FieldActorManager.PreparedMap
---@param sourceMapId integer
---@param self FieldActorManager
function FieldActorManager:commitPrepared(prepared, sourceMapId)
  assert(prepared and prepared.state == "prepared", "prepared map is not committable")
  local entry = prepared.entry
  local destinationMapId = entry.runtimeMap.mapId
  assert(destinationMapId ~= sourceMapId, "prepared destination must differ from source")
  assert(not self.maps[destinationMapId], "prepared destination is already live")

  local bound, bindErr = pcall(bindEventState, self, prepared.eventState)
  if not bound then
    self:discardPrepared(prepared)
    error(bindErr, 0)
  end
  self.maps[destinationMapId] = entry
  self.currentMapId = destinationMapId
  prepared.state = "committed"
  self:leaveMap(sourceMapId)
end

-- Idempotent for an already-active runtime map, so a transition's overlapping
-- load and commit phases cannot duplicate a map's actors.
---@param runtimeMap RuntimeFieldMap
---@param eventState FieldEventState
---@param self FieldActorManager
function FieldActorManager:enterMap(runtimeMap, eventState)
  assert(runtimeMap and runtimeMap.fieldData, "enterMap requires a runtime map")
  assert(eventState, "enterMap requires a field event state")
  local existing = self.maps[runtimeMap.mapId]
  if existing then
    if existing.runtimeMap == runtimeMap then
      bindEventState(self, eventState)
      return
    end
    self:leaveMap(runtimeMap.mapId)
  end
  bindEventState(self, eventState)
  local prepared = self:prepareMap(runtimeMap, eventState)
  self.maps[runtimeMap.mapId] = prepared.entry
  self.currentMapId = runtimeMap.mapId
  prepared.state = "committed"
end

---@param mapId integer
---@param self FieldActorManager
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
---@param change FieldActorStateChange
---@param self FieldActorManager
function FieldActorManager:onEventStateChanged(change)
  if change.kind ~= "flag" then
    return
  end
  local flagChange = change --[[@as FieldActorFlagChange]]
  self.pendingFlags[#self.pendingFlags + 1] = flagChange
end

---@param change FieldActorFlagChange
---@param self FieldActorManager
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

---@param tick integer
---@param self FieldActorManager
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
      -- Scripted pause_animation freezes the actor's pose animation; the
      -- pose clock only advances while the actor is not paused.
      if not actor.animationPaused then
        actor.poseTick = actor.poseTick + 1
      end
    end
  end
end

-- Rebuilds only the physical projection of semantic actors. The staging pass
-- resolves every resident actor and detects occupancy conflicts before any
-- actor or index is changed, so a fixed tick observes one complete index.
---@param self FieldActorManager
function FieldActorManager:reconcilePhysicalWorld()
  for _, entry in pairs(self.maps) do
    local staged = {}
    local stagedOccupancy = {}
    for _, actor in ipairs(entry.order) do
      if isResident(entry.runtimeMap, actor.fieldX, actor.fieldZ) then
        local projection = projectionFor(entry.runtimeMap, actor)
        local key = actor.solid
            and occupancyKey(entry.runtimeMap.mapId, actor.fieldX, actor.fieldZ, projection.surfaceId)
          or nil
        if key and stagedOccupancy[key] then
          Errors.raise(
            FieldErrors.ACTOR_OCCUPANCY_CONFLICT,
            actor.actorId .. " and " .. stagedOccupancy[key].actorId .. " occupy the same field cell and surface",
            {
              actorId = actor.actorId,
              otherActorId = stagedOccupancy[key].actorId,
              mapId = entry.runtimeMap.mapId,
              fieldX = actor.fieldX,
              fieldZ = actor.fieldZ,
              surfaceId = projection.surfaceId,
            }
          )
        end
        if key then
          stagedOccupancy[key] = actor
        end
        staged[#staged + 1] = { actor = actor, projection = projection }
      end
    end

    entry.occupancy = stagedOccupancy
    for _, actor in ipairs(entry.order) do
      actor.resident = false
    end
    for _, item in ipairs(staged) do
      local actor, projection = item.actor, item.projection
      actor:setPosition({
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        cellKey = projection.cellKey,
        sourceSurfaceId = projection.sourceSurfaceId,
        surfaceId = projection.surfaceId,
        worldX = projection.worldX,
        worldY = projection.worldY,
        worldZ = projection.worldZ,
        resident = true,
      })
    end
  end
end

-- Monotonic signal for presentation residency. Movement, facing, pose, and
-- visibility changes do not alter the set of sprite definitions the field
-- presentation must hold.
---@return integer
---@param self FieldActorManager
function FieldActorManager:visualRevision()
  return self._visualRevision
end

-- Add the distinct sprite definitions needed by every live actor to `out`.
-- The caller owns clearing a reused set before collecting a new snapshot.
---@param out table<integer, boolean>
---@param self FieldActorManager
function FieldActorManager:collectSpriteIds(out)
  assert(type(out) == "table", "collectSpriteIds requires a set table")
  for _, entry in pairs(self.maps) do
    for _, actor in ipairs(entry.order) do
      out[actor.spriteId] = true
    end
  end
end

---@return FieldActorManager.DrawRecord[]
---@param self FieldActorManager
function FieldActorManager:drawRecords()
  local records = self._drawRecords
  local count = 0
  for _, entry in pairs(self.maps) do
    for _, actor in ipairs(entry.order) do
      if not actor.resident then
        goto continue
      end
      count = count + 1
      local record = self._drawRecordByActorId[actor.actorId]
      if not record then
        record = {
          actorId = actor.actorId,
          spriteId = actor.spriteId,
          world = { x = actor.worldX, y = actor.worldY, z = actor.worldZ },
          facing = actor.facing,
          pose = actor.pose,
          poseTick = actor.poseTick,
          visible = actor.visible,
        }
        self._drawRecordByActorId[actor.actorId] = record
      end
      record.actorId = actor.actorId
      record.spriteId = actor.spriteId
      record.world.x = actor.worldX
      record.world.y = actor.worldY
      record.world.z = actor.worldZ
      record.facing = actor.facing
      record.pose = actor.pose
      record.poseTick = actor.poseTick
      record.visible = actor.visible
      records[count] = record
      ::continue::
    end
  end
  for index = #records, count + 1, -1 do
    records[index] = nil
  end
  return records
end

---@param actorId string
---@return FieldActorManager.Actor?
---@param self FieldActorManager
function FieldActorManager:getById(actorId)
  for _, entry in pairs(self.maps) do
    local actor = entry.actors[actorId]
    if actor then
      return actor
    end
  end
  return nil
end

---@param mapId integer
---@param fieldX integer
---@param fieldZ integer
---@param surfaceId integer
---@return FieldActorManager.Actor?
---@param self FieldActorManager
function FieldActorManager:getAt(mapId, fieldX, fieldZ, surfaceId)
  local entry = self.maps[mapId]
  if surfaceId == nil then
    return nil
  end
  return entry and entry.occupancy[occupancyKey(mapId, fieldX, fieldZ, surfaceId)] or nil
end

-- Inspect destination object events without creating actors. This deliberately
-- repeats only the event filtering and surface comparison needed for collision;
-- actor construction remains the ownership-bearing path used after a commit.
---@param runtimeMap RuntimeFieldMap
---@param eventState FieldEventState
---@param fieldX integer
---@param fieldZ integer
---@param surfaceId integer
---@return FieldActorManager.ProbeResult?
function FieldActorManager:probeAt(runtimeMap, eventState, fieldX, fieldZ, surfaceId)
  assert(runtimeMap and runtimeMap.fieldData, "probeAt requires a runtime map")
  assert(eventState, "probeAt requires a field event state")
  assert(type(surfaceId) == "number", "probeAt requires a surface id")
  local occupant
  for _, event in ipairs(runtimeMap.fieldData.events.objects) do
    if
      event.x == fieldX
      and event.z == fieldZ
      and not eventState:isFlagSet(event.eventFlag)
      and event.solid ~= false
    then
      local actorId = FieldObjectActor.actorId(runtimeMap.mapId, event.objectEventId)
      local sample = resolveSurface(runtimeMap, event, actorId)
      if sample.surfaceId == surfaceId then
        if occupant then
          Errors.raise(
            FieldErrors.ACTOR_OCCUPANCY_CONFLICT,
            actorId .. " and " .. occupant.actorId .. " occupy the same field cell and surface",
            {
              actorId = actorId,
              otherActorId = occupant.actorId,
              mapId = runtimeMap.mapId,
              fieldX = fieldX,
              fieldZ = fieldZ,
              surfaceId = surfaceId,
            }
          )
        end
        occupant = { actorId = actorId, objectEventId = event.objectEventId }
      end
    end
  end
  return occupant
end

---@param mapId integer
---@param fieldX integer
---@param fieldZ integer
---@param surfaceId integer
---@param exceptActorId string?
---@return boolean
---@param self FieldActorManager
function FieldActorManager:isOccupied(mapId, fieldX, fieldZ, surfaceId, exceptActorId)
  local actor = self:getAt(mapId, fieldX, fieldZ, surfaceId)
  return actor ~= nil and actor.actorId ~= exceptActorId
end

---@param mapId integer
---@return FieldActorManager.Actor[]
---@param self FieldActorManager
function FieldActorManager:actorsOf(mapId)
  local entry = self.maps[mapId]
  return entry and entry.order or {}
end

-- --- Scripted actor API ------------------------------------------------------

-- Alias of `getById` for the script actor world contract.
---@param actorId string
---@return FieldActorManager.Actor?
---@param self FieldActorManager
function FieldActorManager:getActor(actorId)
  return self:getById(actorId)
end

---@param actorId string
---@return FieldActorManager.ActorPosition?
---@param self FieldActorManager
function FieldActorManager:getPosition(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return nil
  end
  return { fieldX = actor.fieldX, fieldZ = actor.fieldZ, worldY = actor.worldY }
end

---@param actorId string
---@return FieldDirection?
---@param self FieldActorManager
function FieldActorManager:getFacing(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return nil
  end
  return actor.facing
end

---@param actorId string
---@param direction FieldDirection
---@param self FieldActorManager
function FieldActorManager:setFacing(actorId, direction)
  local actor = requireActor(self, actorId)
  actor:setFacing(direction)
end

-- Scripted position set: resolves the destination surface from the terrain
-- (an explicit worldY selects the plate at that height; otherwise the actor's
-- current surface is preserved whenever it covers the destination), then
-- rekeys the occupancy index so collision and the draw list never disagree.
-- The whole destination is calculated and validated -- coordinates, surface,
-- and occupancy conflict -- before the actor or the occupancy index is
-- mutated, so a conversion or surface failure leaves the actor exactly where
-- it was. The destination occupancy slot is never overwritten: moving onto
-- another solid actor's cell is a conflict, the same invariant _instantiate
-- enforces.
---@param actorId string
---@param position FieldActorManager.Position
---@param self FieldActorManager
function FieldActorManager:setPosition(actorId, position)
  local actor = requireActor(self, actorId)
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  local resident = isResident(entry.runtimeMap, position.fieldX, position.fieldZ)
  local cellKey = cellKeyFor(position.fieldX, position.fieldZ)
  local sample
  local world
  local sourceSurfaceId = resident and actor.sourceSurfaceId or nil
  if resident then
    local localX, localZ = FieldCoordinates.fieldToLocal(entry.runtimeMap, position.fieldX, position.fieldZ)
    local surfaceOpts = {
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = position.worldY or actor.worldY,
    } ---@type FieldActorSurfaceOptions
    if position.worldY == nil then
      surfaceOpts.currentSurfaceId = actor.surfaceId
    end
    sample = SurfaceResolver.new(entry.runtimeMap.terrain):resolve(surfaceOpts)
    world = FieldCoordinates.fieldToWorld(entry.runtimeMap, position.fieldX, position.fieldZ, sample.worldY)
    local plate = assert(entry.runtimeMap.terrain:plate(sample.surfaceId), "actor destination surface is missing")
    sourceSurfaceId = plate.sourceSurfaceId or sourceSurfaceId
  end

  local newKey = sample and occupancyKey(actor.mapId, position.fieldX, position.fieldZ, sample.surfaceId) or nil
  if resident and actor.solid then
    local occupant = newKey and entry.occupancy[newKey]
    if occupant ~= nil and occupant ~= actor then
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
  end
  if actor.resident and actor.solid then
    local oldKey = occupancyKey(actor.mapId, actor.fieldX, actor.fieldZ, actor.surfaceId)
    if entry.occupancy[oldKey] == actor then
      entry.occupancy[oldKey] = nil
    end
  end
  if resident and actor.solid then
    entry.occupancy[assert(newKey)] = actor
  end
  actor:setPosition({
    fieldX = position.fieldX,
    fieldZ = position.fieldZ,
    worldY = sample and sample.worldY or nil,
    worldX = world and world.x or nil,
    worldZ = world and world.z or nil,
    surfaceId = sample and sample.surfaceId or nil,
    cellKey = cellKey,
    sourceSurfaceId = sourceSurfaceId,
    resident = resident,
  })
end

---@param actorId string
---@param self FieldActorManager
function FieldActorManager:show(actorId)
  local actor = requireActor(self, actorId)
  actor:setVisible(true)
end

---@param actorId string
---@param self FieldActorManager
function FieldActorManager:hide(actorId)
  local actor = requireActor(self, actorId)
  actor:setVisible(false)
end

---@param actorId string
---@param movementType string
---@param self FieldActorManager
function FieldActorManager:setMovementType(actorId, movementType)
  local actor = requireActor(self, actorId)
  actor.scriptMovementType = movementType
end

-- Scripted pause_animation/resume_animation: the actor's pose clock stops
-- advancing while paused (the manager's fixed-tick step honors the flag).
---@param actorId string
---@param paused boolean
---@param self FieldActorManager
function FieldActorManager:setAnimationPaused(actorId, paused)
  local actor = requireActor(self, actorId)
  actor.animationPaused = paused == true
end

-- The numeric local map-object index of one actor (the pinned HGSS object
-- id), used by trigger comparisons.
---@param actorId string
---@return integer?
---@param self FieldActorManager
function FieldActorManager:numericId(actorId)
  local actor = self:getById(actorId)
  return actor and actor.objectEventId or nil
end

-- Resolve a numeric local map-object index to the current map's actor id
-- (the pinned HGSS object-id path used by `S.actorIndex(n)`); nil when the
-- current map has no such object.
---@param index integer
---@return string|nil
---@param self FieldActorManager
function FieldActorManager:actorIdForMapIndex(index)
  local entry = self.currentMapId ~= nil and self.maps[self.currentMapId] or nil
  return entry and entry.byIndex[index] or nil
end

-- The field camera target (pinned HGSS object id 241) of the current map;
-- nil when the map declares no camera target.
---@return string|nil
---@param self FieldActorManager
function FieldActorManager:cameraTargetId()
  return self:actorIdForMapIndex(CAMERA_TARGET_OBJECT_ID)
end

-- The walking partner (pinned HGSS object id 253) of the current map; nil
-- while no Pokémon follows the player.
---@return string|nil
---@param self FieldActorManager
function FieldActorManager:partnerId()
  return self:actorIdForMapIndex(PARTNER_OBJECT_ID)
end

---@param self FieldActorManager
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
