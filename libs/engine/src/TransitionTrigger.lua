-- Classifies HGSS field warps by the metatile behavior byte of their tile and
-- evaluates the two trigger paths the field system uses: inputPath mirrors
-- FieldSystem_CheckMapTransition (facing-tile door, direction-gated standing
-- stairs/warps, standing ladders) and stepPath mirrors FieldSystem_CheckTransition
-- (north/panel/ladder-down/escalator standing warps). Collision alone never
-- infers a transition type; behavior classifies, collision only gates the
-- facing-tile door. Authoritative source: pret/pokeheartgold
-- src/field/field_control.c with TILE_BEHAVIOR_* values from
-- include/constants/metatile_behavior.h (sequential enum, NONE = 255).

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local WarpSystem = require("libs.engine.src.WarpSystem")

local DIRECTION_DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

---@class TransitionTrigger
---@field kind "door"|"stairs"|"directional"|"generic"
---@field triggerMode "facing"|"standing"
---@field behavior integer?
---@field requiredDirections string[]
---@field evaluatesOn "input"|"step"
---@field ladder boolean
---@field warp table?
local TransitionTrigger = {}
TransitionTrigger.__index = TransitionTrigger

-- TILE_BEHAVIOR_* warp-relevant values (pokeheartgold metatile_behavior.h).
local BEHAVIOR = {
  LADDER_NORTH = 60,
  LADDER_SOUTH = 61,
  LADDER_DOWN = 62,
  WARP_STAIRS_EAST = 94,
  WARP_STAIRS_WEST = 95,
  WARP_ENTRANCE_EAST = 98,
  WARP_ENTRANCE_WEST = 99,
  WARP_ENTRANCE_NORTH = 100,
  WARP_ENTRANCE_SOUTH = 101,
  WARP_PANEL = 103,
  DOOR = 105,
  ESCALATOR_FLIP_FACE = 106,
  ESCALATOR = 107,
  WARP_EAST = 108,
  WARP_WEST = 109,
  WARP_NORTH = 110,
  WARP_SOUTH = 111,
}

-- Behavior byte -> semantic classification. requiredDirections is the gate
-- FieldSystem_CheckMapTransition applies (empty = any facing); evaluatesOn
-- selects the trigger path; ladder behaviors additionally return early on a
-- failed gate in the input path (their HGSS branches never fall through).
local CLASSIFICATIONS = {
  [BEHAVIOR.LADDER_NORTH] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "north" },
    evaluatesOn = "input",
    ladder = true,
  },
  [BEHAVIOR.LADDER_SOUTH] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "south" },
    evaluatesOn = "input",
    ladder = true,
  },
  [BEHAVIOR.LADDER_DOWN] = {
    kind = "generic",
    triggerMode = "standing",
    requiredDirections = {},
    evaluatesOn = "step",
  },
  [BEHAVIOR.WARP_STAIRS_EAST] = {
    kind = "stairs",
    triggerMode = "standing",
    requiredDirections = { "east" },
    evaluatesOn = "input",
  },
  [BEHAVIOR.WARP_STAIRS_WEST] = {
    kind = "stairs",
    triggerMode = "standing",
    requiredDirections = { "west" },
    evaluatesOn = "input",
  },
  [BEHAVIOR.WARP_ENTRANCE_EAST] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "east" },
    evaluatesOn = "input",
  },
  [BEHAVIOR.WARP_ENTRANCE_WEST] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "west" },
    evaluatesOn = "input",
  },
  [BEHAVIOR.WARP_ENTRANCE_NORTH] = {
    kind = "generic",
    triggerMode = "standing",
    requiredDirections = {},
    evaluatesOn = "step",
  },
  [BEHAVIOR.WARP_ENTRANCE_SOUTH] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "south" },
    evaluatesOn = "input",
  },
  [BEHAVIOR.WARP_PANEL] = {
    kind = "generic",
    triggerMode = "standing",
    requiredDirections = {},
    evaluatesOn = "step",
  },
  [BEHAVIOR.DOOR] = {
    kind = "door",
    triggerMode = "facing",
    requiredDirections = {},
    evaluatesOn = "input",
  },
  [BEHAVIOR.ESCALATOR_FLIP_FACE] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "east", "west" },
    evaluatesOn = "step",
  },
  [BEHAVIOR.ESCALATOR] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "east", "west" },
    evaluatesOn = "step",
  },
  [BEHAVIOR.WARP_EAST] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "east" },
    evaluatesOn = "input",
  },
  [BEHAVIOR.WARP_WEST] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "west" },
    evaluatesOn = "input",
  },
  [BEHAVIOR.WARP_NORTH] = {
    kind = "generic",
    triggerMode = "standing",
    requiredDirections = {},
    evaluatesOn = "step",
  },
  [BEHAVIOR.WARP_SOUTH] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = { "south" },
    evaluatesOn = "input",
  },
}

---@param behavior integer
---@return TransitionTrigger?
function TransitionTrigger.classify(behavior)
  local record = CLASSIFICATIONS[behavior]
  if not record then
    return nil
  end
  return setmetatable({
    kind = record.kind,
    triggerMode = record.triggerMode,
    requiredDirections = record.requiredDirections,
    evaluatesOn = record.evaluatesOn,
    ladder = record.ladder or false,
  }, TransitionTrigger)
end

---@param facing string
---@return boolean
function TransitionTrigger:matchesDirection(facing)
  for _, required in ipairs(self.requiredDirections) do
    if required == facing then
      return true
    end
  end
  return #self.requiredDirections == 0
end

local function localCoords(runtimeMap, fieldX, fieldZ)
  local origin = runtimeMap.coordinateOrigin
  local localX, localZ = fieldX - origin.x, fieldZ - origin.z
  if not runtimeMap.collision:containsLocal(localX, localZ) then
    return nil
  end
  return localX, localZ
end

-- The metatile behavior byte at a field tile, or nil outside permission
-- coverage (out-of-coverage tiles can never trigger). Shared by the trigger
-- paths and the door/model lookup.
---@param runtimeMap table
---@param fieldX integer
---@param fieldZ integer
---@return integer?
function TransitionTrigger.behaviorAt(runtimeMap, fieldX, fieldZ)
  local localX, localZ = localCoords(runtimeMap, fieldX, fieldZ)
  if not localX then
    return nil
  end
  return runtimeMap.collision:getLocal(localX, localZ).behavior
end

-- Classification of the metatile behavior at a field tile; nil when the tile
-- is outside permission coverage (out-of-coverage tiles can never trigger).
local function classifyAt(runtimeMap, fieldX, fieldZ)
  local behavior = TransitionTrigger.behaviorAt(runtimeMap, fieldX, fieldZ)
  if behavior == nil then
    return nil
  end
  return TransitionTrigger.classify(behavior)
end

local function blockedAt(runtimeMap, fieldX, fieldZ)
  local localX, localZ = localCoords(runtimeMap, fieldX, fieldZ)
  if not localX then
    return nil
  end
  return runtimeMap.collision:isBlockedLocal(localX, localZ)
end

local function attachWarp(classification, runtimeMap, fieldX, fieldZ)
  local warp = WarpSystem.findAt(runtimeMap, fieldX, fieldZ)
  if not warp then
    return nil
  end
  classification.warp = warp
  classification.behavior = TransitionTrigger.behaviorAt(runtimeMap, fieldX, fieldZ)
  return classification
end

-- HGSS FieldSystem_CheckMapTransition: evaluated while the player is idle and
-- presses/holds a direction. Returns a TransitionTrigger (warp attached) or
-- nil when no warp-trigger applies at the player's tile.
---@param runtimeMap table
---@param fieldX integer
---@param fieldZ integer
---@param direction string
---@return TransitionTrigger?
function TransitionTrigger.inputPath(runtimeMap, fieldX, fieldZ, direction)
  local delta = DIRECTION_DELTAS[direction]
  if not delta then
    Errors.raise(FieldErrors.ACTOR_FACING_INVALID, "unsupported player facing " .. tostring(direction), {
      mapId = runtimeMap.mapId,
    })
  end

  -- 1. Standing ladders gate first and return early on a failed gate: their
  --    HGSS branches never fall through to the door checks.
  local standing = classifyAt(runtimeMap, fieldX, fieldZ)
  if standing and standing.ladder then
    if not standing:matchesDirection(direction) then
      return nil
    end
    return attachWarp(standing, runtimeMap, fieldX, fieldZ)
  end

  -- 2. The input path requires a blocked tile directly ahead (the door or
  --    stair wall the player faces); HGSS returns FALSE without it.
  if blockedAt(runtimeMap, fieldX + delta.x, fieldZ + delta.z) ~= true then
    return nil
  end

  -- 3. Facing-tile door: the blocked tile ahead carries a DOOR warp.
  local facing = classifyAt(runtimeMap, fieldX + delta.x, fieldZ + delta.z)
  if facing and facing.kind == "door" then
    local trigger = attachWarp(facing, runtimeMap, fieldX + delta.x, fieldZ + delta.z)
    if trigger then
      return trigger
    end
  end

  -- 4. Standing direction-gated warps (door, stairs, and east/west/south
  --    warp + entrance behaviors; ladders handled above, escalator and
  --    north/panel/ladder-down are step-path only).
  if standing and standing.evaluatesOn == "input" and standing:matchesDirection(direction) then
    return attachWarp(standing, runtimeMap, fieldX, fieldZ)
  end
  return nil
end

-- HGSS FieldSystem_CheckTransition: evaluated when a step completes onto the
-- tile. Returns a TransitionTrigger (warp attached) or nil.
---@param runtimeMap table
---@param fieldX integer
---@param fieldZ integer
---@param facing string
---@return TransitionTrigger?
function TransitionTrigger.stepPath(runtimeMap, fieldX, fieldZ, facing)
  local classification = classifyAt(runtimeMap, fieldX, fieldZ)
  if not classification or classification.evaluatesOn ~= "step" then
    return nil
  end
  if not classification:matchesDirection(facing) then
    return nil
  end
  return attachWarp(classification, runtimeMap, fieldX, fieldZ)
end

-- Exported for fixtures and diagnostics that need the raw TILE_BEHAVIOR_*
-- bytes rather than a classified trigger.
TransitionTrigger.BEHAVIOR = BEHAVIOR

return TransitionTrigger
