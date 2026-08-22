-- Classifies HGSS field warps by the metatile behavior byte of their tile and
-- evaluates the two trigger paths the field system uses: inputPath mirrors
-- FieldSystem_CheckMapTransition (facing-tile door, direction-gated standing
-- stairs/warps, standing ladders) and stepPath mirrors FieldSystem_CheckTransition
-- (north/panel/ladder-down/escalator standing warps). Collision alone never
-- infers a transition type; behavior classifies, collision only gates the
-- facing-tile door. Authoritative source: pret/pokeheartgold
-- src/field/field_control.c with TILE_BEHAVIOR_* values from
-- include/constants/metatile_behavior.h (sequential enum, NONE = 255).
--
-- The trigger paths return the minimum public record the session needs --
-- the classification kind plus the attached warp; the full classification
-- (triggerMode, requiredDirections, evaluatesOn, ladder) stays local to this
-- module's policy. The raw behavior byte vocabulary lives in MetatileBehavior
-- below this module.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local WarpSystem = require("libs.engine.src.WarpSystem")
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")

local DIRECTION_DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

---@class TransitionTriggerClassification -- the full classification: trigger policy internals
---@field kind "door"|"stairs"|"directional"|"generic"
---@field triggerMode "facing"|"standing"
---@field requiredDirections string[]
---@field evaluatesOn "input"|"step"
---@field ladder boolean

---@class TransitionTrigger -- the public trigger record: kind plus the attached warp
---@field kind "door"|"stairs"|"directional"|"generic"
---@field warp table?
local TransitionTrigger = {}

-- The raw behavior byte vocabulary lives in MetatileBehavior, below this
-- module's policy.
local BEHAVIOR = MetatileBehavior.BEHAVIOR

local function entranceDirections(behavior)
  local direction = MetatileBehavior.warpEntranceDirection(behavior)
  return direction and { direction } or {}
end

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
    requiredDirections = entranceDirections(BEHAVIOR.WARP_ENTRANCE_EAST),
    evaluatesOn = "input",
  },
  [BEHAVIOR.WARP_ENTRANCE_WEST] = {
    kind = "directional",
    triggerMode = "standing",
    requiredDirections = entranceDirections(BEHAVIOR.WARP_ENTRANCE_WEST),
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
    requiredDirections = entranceDirections(BEHAVIOR.WARP_ENTRANCE_SOUTH),
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
---@return TransitionTriggerClassification?
function TransitionTrigger.classify(behavior)
  local record = CLASSIFICATIONS[behavior]
  if not record then
    return nil
  end
  -- A fresh plain record per call: callers never receive a shared table.
  return {
    kind = record.kind,
    triggerMode = record.triggerMode,
    requiredDirections = record.requiredDirections,
    evaluatesOn = record.evaluatesOn,
    ladder = record.ladder or false,
  }
end

-- Whether a classification's direction gate admits `facing` (empty gate =
-- any facing).
---@param classification TransitionTriggerClassification
---@param facing string
---@return boolean
function TransitionTrigger.matchesDirection(classification, facing)
  for _, required in ipairs(classification.requiredDirections) do
    if required == facing then
      return true
    end
  end
  return #classification.requiredDirections == 0
end

local function localCoords(runtimeMap, fieldX, fieldZ)
  local origin = runtimeMap.coordinateOrigin
  local collision = runtimeMap.collision
  if not origin or not collision or not collision.containsLocal or not collision.getLocal then
    return nil
  end
  local localX, localZ = fieldX - origin.x, fieldZ - origin.z
  if not collision:containsLocal(localX, localZ) then
    return nil
  end
  return localX, localZ
end

-- The metatile behavior byte at a field tile, or nil outside permission
-- coverage (out-of-coverage tiles can never trigger).
---@param runtimeMap table
---@param fieldX integer
---@param fieldZ integer
---@return integer?
local function behaviorAt(runtimeMap, fieldX, fieldZ)
  local localX, localZ = localCoords(runtimeMap, fieldX, fieldZ)
  if not localX then
    return nil
  end
  return runtimeMap.collision:getLocal(localX, localZ).behavior
end

-- Classification of the metatile behavior at a field tile; nil when the tile
-- is outside permission coverage (out-of-coverage tiles can never trigger).
local function classifyAt(runtimeMap, fieldX, fieldZ)
  local behavior = behaviorAt(runtimeMap, fieldX, fieldZ)
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
  -- The minimal public trigger record: the classification kind plus the
  -- attached warp. The remaining classification data is trigger-policy
  -- internals and never leaves this module.
  return { kind = classification.kind, warp = warp }
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
    if not TransitionTrigger.matchesDirection(standing, direction) then
      return nil
    end
    return attachWarp(standing, runtimeMap, fieldX, fieldZ)
  end

  -- 2. Collision gates only the facing-tile door probe. Standing input
  --    warps are evaluated independently of the tile ahead.
  if blockedAt(runtimeMap, fieldX + delta.x, fieldZ + delta.z) == true then
    local facing = classifyAt(runtimeMap, fieldX + delta.x, fieldZ + delta.z)
    if facing and facing.kind == "door" then
      local trigger = attachWarp(facing, runtimeMap, fieldX + delta.x, fieldZ + delta.z)
      if trigger then
        return trigger
      end
    end
  end

  -- 4. Standing direction-gated warps (door, stairs, and east/west/south
  --    warp + entrance behaviors; ladders handled above, escalator and
  --    north/panel/ladder-down are step-path only).
  if standing and standing.evaluatesOn == "input" and TransitionTrigger.matchesDirection(standing, direction) then
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
  if not TransitionTrigger.matchesDirection(classification, facing) then
    return nil
  end
  return attachWarp(classification, runtimeMap, fieldX, fieldZ)
end

return TransitionTrigger
