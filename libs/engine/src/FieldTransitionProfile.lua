-- Selects the small set of HGSS transition profiles represented by the field
-- runtime. Trigger mechanics remain separate from map-class profile identity.

local FieldTransitionProfile = {}
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

FieldTransitionProfile.DOOR = 1
FieldTransitionProfile.ESCALATOR = 2
FieldTransitionProfile.HORIZONTAL_STAIRS = 3
FieldTransitionProfile.ORDINARY_INDOOR = 6
FieldTransitionProfile.LADDER = 7
FieldTransitionProfile.LADDER_DOWN = 8
FieldTransitionProfile.ORDINARY = 0

FieldTransitionProfile.MODE_FIXED = "fixed"
FieldTransitionProfile.MODE_PANEL = "panel"
FieldTransitionProfile.MODE_ENVIRONMENT = "environment"

FieldTransitionProfile.ROUTINES = {
  [0] = "ordinary",
  [1] = "door",
  [2] = "escalator",
  [3] = "horizontal_stairs",
  [4] = "cave",
  [5] = "outdoor",
  [6] = "ordinary_indoor",
  [7] = "ladder",
  [8] = "ladder_down",
}

-- The source task table is kept as semantic routine families.  Consumers use
-- the names to select choreography; they do not need to know the source
-- symbol that introduced each family.
FieldTransitionProfile.ROUTINE_FAMILIES = {
  [0] = { exit = "ordinary_exit", enter = "ordinary_enter" },
  [1] = { exit = "door_exit", enter = "door_enter" },
  [2] = { exit = "escalator_exit", enter = "escalator_enter", adjustment = "escalator", sound = "SEQ_SE_GS_UFO_JUMP" },
  [3] = { exit = "horizontal_stairs_exit", enter = "horizontal_stairs_enter", adjustment = "horizontal_stairs" },
  [4] = { exit = "cave_exit", enter = "cave_enter", sound = "SEQ_SE_PL_WARP" },
  [5] = { exit = "outdoor_exit", enter = "outdoor_enter", sound = "SEQ_SE_PL_WARP" },
  [6] = { exit = "ordinary_exit", enter = "indoor_enter" },
  [7] = { exit = "ladder_exit", enter = "ladder_enter", adjustment = "ladder", sound = "SEQ_SE_GS_UFO_JUMP" },
  [8] = {
    exit = "ladder_down_exit",
    enter = "ladder_down_enter",
    adjustment = "ladder_down",
    sound = "SEQ_SE_GS_UFO_JUMP",
  },
}

---@param profile integer
---@return boolean
function FieldTransitionProfile.isValid(profile)
  return type(profile) == "number" and profile % 1 == 0 and profile >= 0 and profile <= 8
end

local ENVIRONMENT_PROFILES = {
  cave = { cave = 6, outdoors = 5, building = 6 },
  outdoors = { cave = 4, building = 6 },
  building = { cave = 0, outdoors = 0, building = 6 },
}

---@param sourceEnvironment string
---@param destinationEnvironment string
---@return integer
function FieldTransitionProfile.selectEnvironment(sourceEnvironment, destinationEnvironment, context)
  local sourceProfiles = ENVIRONMENT_PROFILES[sourceEnvironment]
  local profile = sourceProfiles and sourceProfiles[destinationEnvironment]
  if profile == nil then
    Errors.raise(
      FieldErrors.MAP_TRANSITION_PROFILE_UNSUPPORTED,
      "unsupported transition environment pair: "
        .. tostring(sourceEnvironment)
        .. " -> "
        .. tostring(destinationEnvironment),
      context or { sourceEnvironment = sourceEnvironment, destinationEnvironment = destinationEnvironment }
    )
  end
  return assert(profile)
end

---@param profile integer
---@return table
function FieldTransitionProfile.fixed(profile)
  assert(FieldTransitionProfile.isValid(profile), "transition profile must be an integer from 0 through 8")
  return { mode = FieldTransitionProfile.MODE_FIXED, profile = profile }
end

---@param mode "panel"|"environment"
---@return table
function FieldTransitionProfile.mode(mode)
  assert(mode == FieldTransitionProfile.MODE_PANEL or mode == FieldTransitionProfile.MODE_ENVIRONMENT)
  return { mode = mode }
end

return FieldTransitionProfile
