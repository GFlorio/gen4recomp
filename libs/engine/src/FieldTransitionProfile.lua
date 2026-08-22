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
  return { mode = FieldTransitionProfile.MODE_FIXED, profile = profile }
end

---@param mode "panel"|"environment"
---@return table
function FieldTransitionProfile.mode(mode)
  assert(mode == FieldTransitionProfile.MODE_PANEL or mode == FieldTransitionProfile.MODE_ENVIRONMENT)
  return { mode = mode }
end

return FieldTransitionProfile
