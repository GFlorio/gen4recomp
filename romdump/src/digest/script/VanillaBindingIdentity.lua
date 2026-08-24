-- Validates canonical vanilla coordinate-script IDs against HGSS source identity.
-- MapCatalog supplies the script archive member and ZoneEvents supplies the
-- source's one-based script selector; runtime binding resolution stays unaware
-- of both source details.

local Errors = require("libs.errors.src.Errors")

local VanillaBindingIdentity = {}

local CANONICAL_PATTERN = "^vanilla%.hgss%.scr_seq%.(%d%d%d%d)%.script_(%d%d%d)$"

local function invalid(scriptId)
  return Errors.new(
    "VANILLA_BINDING_IDENTITY_INVALID",
    string.format("coordinate source script selector must be at least 1, got %s", tostring(scriptId)),
    { scriptId = scriptId }
  )
end

---@param target string
---@return { memberId: integer, scriptIndex: integer }|nil
function VanillaBindingIdentity.parseCanonicalTarget(target)
  if type(target) ~= "string" then
    return nil
  end
  local memberText, scriptText = target:match(CANONICAL_PATTERN)
  if memberText == nil then
    return nil
  end
  return {
    memberId = tonumber(memberText),
    scriptIndex = tonumber(scriptText),
  }
end

---@param mapRecord { scriptsMemberId: integer }
---@param coordinateEvent { scriptId: integer }
---@return string|nil, table|nil
function VanillaBindingIdentity.expectedCoordinateTarget(mapRecord, coordinateEvent)
  assert(type(mapRecord) == "table", "mapRecord must be a table")
  assert(type(coordinateEvent) == "table", "coordinateEvent must be a table")
  local scriptId = coordinateEvent.scriptId
  if type(scriptId) ~= "number" or scriptId < 1 or scriptId % 1 ~= 0 then
    return nil, invalid(scriptId)
  end
  assert(type(mapRecord.scriptsMemberId) == "number", "mapRecord.scriptsMemberId must be a number")
  return string.format("vanilla.hgss.scr_seq.%04d.script_%03d", mapRecord.scriptsMemberId, scriptId - 1)
end

---@param mapId integer
---@param eventIndex integer
---@param target string
---@param mapRecord { scriptsMemberId: integer }
---@param coordinateEvent { scriptId: integer }
---@return boolean|nil, table|nil
function VanillaBindingIdentity.validateCoordinateTarget(mapId, eventIndex, target, mapRecord, coordinateEvent)
  if VanillaBindingIdentity.parseCanonicalTarget(target) == nil then
    return true
  end

  local expectedTarget, err = VanillaBindingIdentity.expectedCoordinateTarget(mapRecord, coordinateEvent)
  if expectedTarget == nil then
    return nil, err
  end
  if target == expectedTarget then
    return true
  end

  return nil,
    Errors.new(
      "VANILLA_BINDING_IDENTITY_MISMATCH",
      string.format(
        "map %s coordinate %s expects %s, got %s",
        tostring(mapId),
        tostring(eventIndex),
        expectedTarget,
        target
      ),
      {
        mapId = mapId,
        eventIndex = eventIndex,
        scriptsMemberId = mapRecord.scriptsMemberId,
        scriptId = coordinateEvent.scriptId,
        expectedTarget = expectedTarget,
        actualTarget = target,
      }
    )
end

return VanillaBindingIdentity
