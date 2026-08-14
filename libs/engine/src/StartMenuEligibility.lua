-- Pure idle-boundary open eligibility for the Start Menu: the §17.2 gate the
-- field session consults before an open edge may acquire modal focus or the
-- world-movement pause. The menu may open only at a settled field boundary --
-- player idle, transition idle, no dialogue/signpost/script menu/context
-- choice/application active, no foreground script and no script-owned
-- player-movement lock. One strict snapshot carries every condition (all keys
-- required, no `or false` defaults); evaluate() is a pure predicate and the
-- decide() contract carries the menu-wins-over-action edge rule: an eligible
-- menu open reports "clear" for a simultaneously arriving Action edge so the
-- winning open cannot also trigger the facing interaction, while an
-- ineligible open edge acquires nothing and leaves the Action edge untouched.
-- Pure domain module: no love, no I/O, no registries; the caller (the
-- application-host composition) builds the snapshot from the session.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

local StartMenuEligibility = {}

-- The required snapshot keys; every value is a boolean except playerMotion,
-- which is the FieldPlayer.motion vocabulary (only "idle" is eligible).
local BOOLEAN_FIELDS = {
  "transitionIdle",
  "dialogueModal",
  "signpostModal",
  "scriptMenuModal",
  "contextChoiceActive",
  "applicationActive",
  "foregroundScript",
  "movementLocked",
}

local function invalidSnapshot(message, context)
  Errors.raise(FieldErrors.START_MENU_ELIGIBILITY_INVALID_SNAPSHOT, message, context)
end

-- Strict snapshot validation (raising): every key required, no unknown keys,
-- booleans boolean and playerMotion a valid motion name.
---@param value table
---@return boolean motionIdle
---@return table fields
local function validateSnapshot(value)
  if type(value) ~= "table" then
    invalidSnapshot("the start menu eligibility snapshot must be a table")
  end
  for key in pairs(value) do
    if key ~= "playerMotion" then
      local known = false
      for _, field in ipairs(BOOLEAN_FIELDS) do
        if key == field then
          known = true
        end
      end
      if not known then
        invalidSnapshot("unknown eligibility snapshot key", { key = key })
      end
    end
  end
  if value.playerMotion == nil then
    invalidSnapshot("the snapshot must carry the player motion")
  end
  if value.playerMotion ~= "idle" and value.playerMotion ~= "walking" and value.playerMotion ~= "climbing" then
    invalidSnapshot("unknown player motion", { motion = value.playerMotion })
  end
  for _, field in ipairs(BOOLEAN_FIELDS) do
    if type(value[field]) ~= "boolean" then
      invalidSnapshot("the eligibility condition is required", { field = field })
    end
  end
  return value.playerMotion == "idle", value
end

-- Whether one snapshot condition blocks the open eligibility. transitionIdle
-- is the inverted boolean: a busy transition blocks, an idle one does not.
---@param field string
---@param value boolean
---@return boolean
local function blocksEligibility(field, value)
  if field == "transitionIdle" then
    return not value
  end
  return value
end

-- Whether the Start Menu may open at this field boundary. Pure: nothing is
-- acquired or mutated; an ineligible edge simply gets no open.
---@param snapshot table the strict eligibility snapshot
---@return boolean
function StartMenuEligibility.evaluate(snapshot)
  local motionIdle, fields = validateSnapshot(snapshot)
  if not motionIdle then
    return false
  end
  for _, field in ipairs(BOOLEAN_FIELDS) do
    if blocksEligibility(field, fields[field]) then
      return false
    end
  end
  return true
end

-- The session-facing arbitration. Returns:
--   { menu = "open", action = "clear" }   menu opens and wins; the caller must
--                                         clear a simultaneous Action edge
--   { menu = "open", action = "keep" }    menu opens; no Action edge arrived
--   { menu = "ignore", action = "keep" }  no eligible open; nothing acquired
---@param snapshot table the strict eligibility snapshot
---@param edges { menuPressed: boolean, actionPressed?: boolean } the semantic edges of the tick
---@return { menu: "open"|"ignore", action: "clear"|"keep" }
function StartMenuEligibility.decide(snapshot, edges)
  assert(type(edges) == "table", "the eligibility decision requires the tick edges")
  assert(type(edges.menuPressed) == "boolean", "the decision requires the menu edge state")
  local actionPressed = edges.actionPressed
  assert(actionPressed == nil or type(actionPressed) == "boolean", "the action edge must be a boolean")
  if not StartMenuEligibility.evaluate(snapshot) or not edges.menuPressed then
    return { menu = "ignore", action = "keep" }
  end
  return { menu = "open", action = actionPressed and "clear" or "keep" }
end

return StartMenuEligibility
