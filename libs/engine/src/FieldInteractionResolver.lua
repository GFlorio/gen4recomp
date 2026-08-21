-- Discovers script-neutral facing interactions. Mirrors the original
-- normal-field action order (pret/pokeheartgold `src/field/field_control.c`
-- and `asm/unk_0203DB6C.s`): the facing object actor wins, then a compatible
-- background event on the facing tile, then nothing. The background direction
-- compatibility table is the pinned assembly's `BgEventDirectionIsCompatibleWithPlayerFacing`
-- (raw 4 is a wildcard; facing 0/1/2/3 accept {0,6}/{3,6}/{2,5}/{1,5}).
--
-- The session owns interaction eligibility timing:
-- calling resolve means the player is idle, the Action edge is present, and
-- no transition or modal is active. This module answers only what is in front
-- of the player. A facing cell outside coverage or beyond the reachable step
-- height is an expected boundary and resolves to nothing; malformed,
-- ambiguous, or current-inconsistent terrain propagates instead of reading
-- as a miss.
--
-- The resolver never turns an actor, locks the player, selects a message, or
-- touches presentation: it returns an immutable InteractionIntent (fresh
-- numbers and strings only) or nil. An object is eligible regardless of its
-- raw scriptId -- the original always starts the scene script with the raw
-- u16 -- except script id 0, the no-interaction marker (the original starts
-- the map bank's script 0 there; the project treats that as noninteractive).
-- Type-2
-- background events are the hidden-item family, declared noninteractive:
-- their pickup scripts depend on collection flags that are not tracked, so
-- the resolver never emits an intent for them (see `isHiddenItem`).
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")

---@class FieldInteractionResolver
---@field actorAt fun(mapId: integer, fieldX: integer, fieldZ: integer, surfaceId: integer): table|nil
---@field _surfaceResolver SurfaceResolver?
local FieldInteractionResolver = {}
FieldInteractionResolver.__index = FieldInteractionResolver

---@class InteractionObjectIdentity
---@field actorId string
---@field objectEventId integer
---@field spriteId integer

---@class InteractionBackgroundIdentity
---@field eventIndex integer
---@field type integer
---@field direction integer

---@class InteractionIntent
---@field kind "object"|"background"
---@field mapId integer
---@field sourceFieldX integer
---@field sourceFieldZ integer
---@field sourceSurfaceId integer
---@field targetFieldX integer
---@field targetFieldZ integer
---@field playerFacing FieldDirection
---@field scriptBankId integer?
---@field scriptId integer
---@field object InteractionObjectIdentity?
---@field background InteractionBackgroundIdentity?
---@field tick integer

---@class InteractionResolverSnapshot
---@field runtimeMap RuntimeFieldMap
---@field fieldX integer
---@field fieldZ integer
---@field surfaceId integer
---@field worldY number
---@field facing FieldDirection
---@field tick integer

---@class FieldInteractionResolverOptions
---@field actorAt fun(mapId: integer, fieldX: integer, fieldZ: integer, surfaceId: integer): table|nil

-- Named facing -> raw player-facing code. Raw codes match the zone-event
-- decoder's DIRECTIONS table (0 north, 1 south, 2 west, 3 east).
FieldInteractionResolver.RAW_FACING = { north = 0, south = 1, west = 2, east = 3 }

-- Raw background direction code that matches every player facing
-- (`BgEventDirectionIsCompatibleWithPlayerFacing`, asm/unk_0203DB6C.s).
FieldInteractionResolver.BACKGROUND_DIRECTION_WILDCARD = 4

-- Background event type of the hidden-item family. Hidden items carry
-- pickup scripts (the hidden-item script ids) whose collection-flag state is
-- not tracked yet, so the family is declared noninteractive: the resolver
-- never emits an intent for it. `isHiddenItem` is the single owner of this
-- classification.
FieldInteractionResolver.HIDDEN_ITEM_EVENT_TYPE = 2

---@param event table
---@return boolean
function FieldInteractionResolver.isHiddenItem(event)
  return event.type == FieldInteractionResolver.HIDDEN_ITEM_EVENT_TYPE
end

-- Player facing raw code -> background event raw direction codes that
-- resolve. Derived from `BgEventDirectionIsCompatibleWithPlayerFacing`
-- (asm/unk_0203DB6C.s); BACKGROUND_DIRECTION_WILDCARD is handled separately.
local COMPATIBLE_DIRECTIONS = {
  [0] = { 0, 6 },
  [1] = { 3, 6 },
  [2] = { 2, 5 },
  [3] = { 1, 5 },
}

local DIRECTION_DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

-- Named pure function for the raw direction compatibility table.
-- BACKGROUND_DIRECTION_WILDCARD matches every facing.
---@param playerFacingRaw integer
---@param backgroundDirectionRaw integer
---@return boolean
function FieldInteractionResolver.backgroundDirectionCompatible(playerFacingRaw, backgroundDirectionRaw)
  if backgroundDirectionRaw == FieldInteractionResolver.BACKGROUND_DIRECTION_WILDCARD then
    return true
  end
  local compatible = COMPATIBLE_DIRECTIONS[playerFacingRaw]
  if not compatible then
    return false
  end
  for _, code in ipairs(compatible) do
    if code == backgroundDirectionRaw then
      return true
    end
  end
  return false
end

-- opts.actorAt: function(mapId, fieldX, fieldZ, surfaceId) -> actor | nil.
-- The actor manager's occupancy index is the lookup;
-- hidden actors never appear there.
---@param opts FieldInteractionResolverOptions
---@return FieldInteractionResolver
function FieldInteractionResolver.new(opts)
  assert(
    type(opts) == "table" and type(opts.actorAt) == "function",
    "FieldInteractionResolver requires an actor lookup"
  )
  return setmetatable({
    actorAt = opts.actorAt,
    _surfaceResolver = nil,
  }, FieldInteractionResolver)
end

-- Expected boundary failures mean "nothing interactable there": the facing
-- cell outside permission coverage, or its terrain beyond the reachable step
-- height. Malformed or ambiguous terrain, and a current surface inconsistent
-- with the player's position, are corrupted state and propagate instead of
-- reading as a miss.
local function isBoundaryFailure(err)
  return Errors.is(err) and (err.code == "FIELD_COORDINATES_OUT_OF_COVERAGE" or SurfaceResolver.isStepRejection(err))
end

-- The facing tile is one cardinal field cell from the player's logical
-- settled cell, resolved through the map coordinate profile. Returns the
-- resolved surface sample of the cell, or nil when the cell is not reachable
-- from the player's surface (an expected boundary). The sample is the lookup
-- key for object interactions, so a cross-surface boundary resolves actors
-- on the facing cell's actual surface rather than the player's.
-- The surface resolver is owned by the resolver and rebuilt only when the
-- map terrain changes: the terrain table is the full configuration of the
-- surface selection, so the ownership key is the terrain itself.
function FieldInteractionResolver:_resolveFacingCell(snapshot, targetX, targetZ)
  local map = snapshot.runtimeMap
  local ok, localX, localZ = pcall(FieldCoordinates.fieldToLocal, map, targetX, targetZ)
  if not ok then
    if not isBoundaryFailure(localX) then
      error(localX)
    end
    return nil
  end
  local surfaceResolver = self._surfaceResolver
  if surfaceResolver == nil or surfaceResolver.terrain ~= map.terrain then
    surfaceResolver = SurfaceResolver.new(map.terrain)
    self._surfaceResolver = surfaceResolver
  end
  local okSample, sample = pcall(function()
    return surfaceResolver:resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentSurfaceId = snapshot.surfaceId,
      currentY = snapshot.worldY,
      crossing = {
        fromX = snapshot.fieldX - map.coordinateOrigin.x + FieldCoordinates.TILE_CENTER_OFFSET,
        fromZ = snapshot.fieldZ - map.coordinateOrigin.z + FieldCoordinates.TILE_CENTER_OFFSET,
        toX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
        toZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      },
    })
  end)
  if not okSample then
    if not isBoundaryFailure(sample) then
      error(sample)
    end
    return nil
  end
  return sample
end

-- Scans background events in source order and returns the first eligible
-- record, or nil. Type-2 records (the hidden-item family) are declared
-- noninteractive and never eligible, and script-id-0 records are
-- noninteractive (the no-interaction marker); every other type must pass the
-- raw direction compatibility check.
function FieldInteractionResolver:_firstEligibleBackground(snapshot, targetX, targetZ)
  local map = snapshot.runtimeMap
  local events = assert(map.fieldData.events.background, "runtime map background events required")
  local playerRaw =
    assert(FieldInteractionResolver.RAW_FACING[snapshot.facing], "unknown player facing " .. tostring(snapshot.facing))
  for _, event in ipairs(events) do
    if
      event.x == targetX
      and event.z == targetZ
      and not FieldInteractionResolver.isHiddenItem(event)
      and event.scriptId ~= 0
      and FieldInteractionResolver.backgroundDirectionCompatible(playerRaw, event.directionRaw)
    then
      return event
    end
  end
  return nil
end

-- The intent fields every interaction shares. The immutable identity
-- (object or background) is attached by the caller.
local function baseIntent(kind, snapshot, targetX, targetZ, scriptId)
  local map = snapshot.runtimeMap
  return {
    kind = kind,
    mapId = map.mapId,
    sourceFieldX = snapshot.fieldX,
    sourceFieldZ = snapshot.fieldZ,
    sourceSurfaceId = snapshot.surfaceId,
    targetFieldX = targetX,
    targetFieldZ = targetZ,
    playerFacing = snapshot.facing,
    scriptBankId = map.fieldData and map.fieldData.scriptBankId or nil,
    scriptId = scriptId,
    object = nil,
    background = nil,
    tick = snapshot.tick,
  }
end

-- Resolves one Action press into an immutable InteractionIntent or nil.
---@param snapshot InteractionResolverSnapshot
---@return InteractionIntent?
function FieldInteractionResolver:resolve(snapshot)
  assert(type(snapshot) == "table" and type(snapshot.runtimeMap) == "table", "resolve requires a runtime map")

  local map = snapshot.runtimeMap
  local delta = DIRECTION_DELTAS[snapshot.facing]
  if not delta then
    Errors.raise(
      FieldErrors.ACTOR_FACING_INVALID,
      "unsupported player facing " .. tostring(snapshot.facing),
      { mapId = map.mapId }
    )
  end
  local targetX, targetZ = snapshot.fieldX + delta.x, snapshot.fieldZ + delta.z

  local targetSample = self:_resolveFacingCell(snapshot, targetX, targetZ)
  if not targetSample then
    return nil
  end

  -- Object actors first: the occupancy index is keyed by the exact surface,
  -- and the key is the facing cell's RESOLVED surface, so a cross-surface
  -- boundary looks up the actor where it actually stands, and a same-x/z
  -- actor on another surface stays ineligible. A script-id-0 actor is
  -- noninteractive and resolves to nothing: the interaction the original
  -- would start (bank script 0) is not implemented, so the intent must not
  -- reach the script client.
  local actor = self.actorAt(map.mapId, targetX, targetZ, targetSample.surfaceId)
  if actor then
    if actor.sourceEvent.scriptId == 0 then
      return nil
    end
    local intent = baseIntent("object", snapshot, targetX, targetZ, actor.sourceEvent.scriptId)
    intent.object = {
      actorId = actor.actorId,
      objectEventId = actor.objectEventId,
      spriteId = actor.spriteId,
    }
    return intent
  end

  -- Background events second, in source order.
  local event = self:_firstEligibleBackground(snapshot, targetX, targetZ)
  if event then
    local intent = baseIntent("background", snapshot, targetX, targetZ, event.scriptId)
    intent.background = {
      eventIndex = event.index,
      type = event.type,
      direction = event.directionRaw,
    }
    return intent
  end

  return nil
end

return FieldInteractionResolver
