-- Discovers script-neutral facing interactions. Mirrors the original
-- normal-field action order (pret/pokeheartgold `src/field/field_control.c`
-- and `asm/unk_0203DB6C.s`): the facing object actor wins, then a compatible
-- background event on the facing tile, then nothing. The background direction
-- compatibility table is the pinned assembly's `BgEventDirectionIsCompatibleWithPlayerFacing`
-- (raw 4 is a wildcard; facing 0/1/2/3 accept {0,6}/{3,6}/{2,5}/{1,5}).
--
-- Eligibility gates (spec section 12.2) are checked here so the module is
-- testable headlessly: no transition, no modal, player idle, Action edge,
-- and the facing tile resolving inside the map's coordinate profile.
--
-- The resolver never turns an actor, locks the player, selects a message, or
-- touches presentation: it returns an immutable InteractionIntent (fresh
-- numbers and strings only) or nil. An object is eligible regardless of its
-- raw scriptId -- the original always starts the scene script with the raw
-- u16, so 0 or 0xFFFF is the script engine's business, not ours. Type-2
-- background events are the hidden-item path and depend on collection flags
-- that this milestone does not track: they are traced and skipped. Pure
-- domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")

local FieldInteractionResolver = {}
FieldInteractionResolver.__index = FieldInteractionResolver

-- Named facing -> raw player-facing code. Raw codes match the zone-event
-- decoder's DIRECTIONS table (0 north, 1 south, 2 west, 3 east).
FieldInteractionResolver.RAW_FACING = { north = 0, south = 1, west = 2, east = 3 }

-- Player facing raw code -> background event raw direction codes that
-- resolve. Derived from `BgEventDirectionIsCompatibleWithPlayerFacing`
-- (asm/unk_0203DB6C.s); raw 4 is handled separately as a wildcard.
local COMPATIBLE_DIRECTIONS = {
  [0] = { 0, 6 },
  [1] = { 3, 6 },
  [2] = { 2, 5 },
  [3] = { 1, 5 },
}

local DIRECTION_DELTAS = {
  north = { x = 0, z = -1 }, south = { x = 0, z = 1 },
  west = { x = -1, z = 0 }, east = { x = 1, z = 0 },
}

-- Named pure function for the raw direction compatibility table (spec
-- section 12.5). Background direction raw 4 is the "any facing" wildcard.
---@param playerFacingRaw integer
---@param backgroundDirectionRaw integer
---@return boolean
function FieldInteractionResolver.backgroundDirectionCompatible(playerFacingRaw, backgroundDirectionRaw)
  if backgroundDirectionRaw == 4 then return true end
  local compatible = COMPATIBLE_DIRECTIONS[playerFacingRaw]
  if not compatible then return false end
  for _, code in ipairs(compatible) do
    if code == backgroundDirectionRaw then return true end
  end
  return false
end

-- opts.actorAt: function(mapId, fieldX, fieldZ, surfaceId) -> actor | nil.
-- The actor manager's occupancy index is the lookup (spec section 12.4);
-- hidden actors never appear there.
-- opts.trace: optional developer sink for structured records.
function FieldInteractionResolver.new(opts)
  assert(type(opts) == "table" and type(opts.actorAt) == "function",
    "FieldInteractionResolver requires an actor lookup")
  return setmetatable({
    actorAt = opts.actorAt,
    trace = opts.trace,
  }, FieldInteractionResolver)
end

function FieldInteractionResolver:_trace(record)
  if self.trace then self.trace(record) end
end

-- The facing tile is one cardinal field cell from the player's logical
-- settled cell, resolved through the map coordinate profile (a cell outside
-- permission coverage raises FIELD_COORDINATES_OUT_OF_COVERAGE and yields
-- false). Returns whether the cell is reachable from the player's surface.
-- Background events have no actor surface of their own, so this is the
-- eligibility rule of spec section 12.6.
function FieldInteractionResolver:_facingCellReachable(snapshot, targetX, targetZ)
  local map = snapshot.runtimeMap
  local ok, localX, localZ = pcall(FieldCoordinates.fieldToLocal, map, targetX, targetZ)
  if not ok then return false end
  local okSample = pcall(function()
    return SurfaceResolver.new(map.terrain):resolve({
      localX = localX + 0.5,
      localZ = localZ + 0.5,
      currentSurfaceId = snapshot.surfaceId,
      currentY = snapshot.worldY,
      crossing = {
        fromX = snapshot.fieldX - map.coordinateOrigin.x + 0.5,
        fromZ = snapshot.fieldZ - map.coordinateOrigin.z + 0.5,
        toX = localX + 0.5,
        toZ = localZ + 0.5,
      },
    })
  end)
  return okSample
end

-- Scans background events in source order and returns the first eligible
-- record, or nil. Type-2 records (the hidden-item path) are traced and
-- skipped because their collection flags are not tracked yet; every other
-- type must pass the raw direction compatibility check.
function FieldInteractionResolver:_firstEligibleBackground(snapshot, targetX, targetZ)
  local map = snapshot.runtimeMap
  local events = map.fieldData and map.fieldData.events and map.fieldData.events.background or {}
  local playerRaw = assert(FieldInteractionResolver.RAW_FACING[snapshot.facing],
    "unknown player facing " .. tostring(snapshot.facing))
  local matched
  for _, event in ipairs(events) do
    if event.x == targetX and event.z == targetZ then
      if event.type == 2 then
        self:_trace({
          kind = "field.interaction.background_type2_deferred",
          mapId = map.mapId, eventIndex = event.index, scriptId = event.scriptId,
        })
      elseif FieldInteractionResolver.backgroundDirectionCompatible(playerRaw, event.directionRaw) then
        if matched then
          self:_trace({
            kind = "field.interaction.multiple_background_candidates",
            mapId = map.mapId, eventIndex = matched.index, otherIndex = event.index,
          })
        else
          matched = event
        end
      end
    end
  end
  return matched
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

-- The resolved trace record; the identity table (intent.object or
-- intent.background) already carries the kind-specific fields.
local function resolvedTrace(intent, identity)
  return {
    kind = "field.interaction.resolved",
    intentKind = intent.kind,
    mapId = intent.mapId,
    scriptBankId = intent.scriptBankId,
    scriptId = intent.scriptId,
    playerFacing = intent.playerFacing,
    targetFieldX = intent.targetFieldX,
    targetFieldZ = intent.targetFieldZ,
    tick = intent.tick,
    objectEventId = identity.objectEventId,
    spriteId = identity.spriteId,
    eventIndex = identity.eventIndex,
    type = identity.type,
  }
end

-- Resolves one Action press into an immutable InteractionIntent or nil.
-- snapshot fields:
--   runtimeMap, mapId, fieldX, fieldZ, surfaceId, worldY, facing,
--   playerIdle, actionPressed, transitionActive, modalActive, tick
function FieldInteractionResolver:resolve(snapshot)
  assert(type(snapshot) == "table" and type(snapshot.runtimeMap) == "table",
    "resolve requires a runtime map")
  if not snapshot.playerIdle then return nil end
  if not snapshot.actionPressed then return nil end
  if snapshot.transitionActive then return nil end
  if snapshot.modalActive then return nil end

  local map = snapshot.runtimeMap
  local delta = DIRECTION_DELTAS[snapshot.facing]
  if not delta then
    Errors.raise("ACTOR_FACING_INVALID", "unsupported player facing " .. tostring(snapshot.facing),
      { mapId = map.mapId })
  end
  local targetX, targetZ = snapshot.fieldX + delta.x, snapshot.fieldZ + delta.z

  if not self:_facingCellReachable(snapshot, targetX, targetZ) then
    self:_trace({ kind = "field.interaction.none", mapId = map.mapId,
      playerFacing = snapshot.facing, reason = "facing_tile_unreachable" })
    return nil
  end

  -- Object actors first: the occupancy index is keyed by the exact surface,
  -- so a same-x/z actor on another surface is ineligible (spec 12.6).
  local actor = self.actorAt(map.mapId, targetX, targetZ, snapshot.surfaceId)
  if actor then
    local intent = baseIntent("object", snapshot, targetX, targetZ, actor.sourceEvent.scriptId)
    intent.object = {
      actorId = actor.actorId,
      objectEventId = actor.objectEventId,
      spriteId = actor.spriteId,
    }
    self:_trace(resolvedTrace(intent, intent.object))
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
    self:_trace(resolvedTrace(intent, intent.background))
    return intent
  end

  self:_trace({ kind = "field.interaction.none", mapId = map.mapId,
    playerFacing = snapshot.facing, targetFieldX = targetX, targetFieldZ = targetZ })
  return nil
end

return FieldInteractionResolver
