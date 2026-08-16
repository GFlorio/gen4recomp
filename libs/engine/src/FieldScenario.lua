-- Applies a project-owned deterministic scenario to a clean FieldEventState.
-- The manifest names objects by stable map/object identity; this module resolves
-- each to the numeric ROM event flag from compiled map data, so no hand-copied
-- flag number can drift from the ROM. It seeds a demo, never retail new-game
-- initialization, and is applied only when an event store is first created.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")

local FieldScenario = {}

local function fail(message, context)
  Errors.raise(FieldErrors.SCENARIO_FLAG_RESOLUTION_FAILED, message, context)
end

local function resolveFlag(entry, fieldDataFor)
  local fieldData = fieldDataFor(entry.mapId)
  local events = type(fieldData) == "table" and fieldData.events or nil
  if not FieldMapDataCache.hasRequiredEvents(events) then
    fail(
      "scenario references map " .. tostring(entry.mapId) .. ", which has no compiled event data",
      { mapId = entry.mapId, objectEventId = entry.objectEventId }
    )
  end
  for _, event in ipairs(fieldData.events.objects) do
    if event.objectEventId == entry.objectEventId then
      if event.eventFlag == 0 then
        fail(
          "object event "
            .. entry.objectEventId
            .. " on map "
            .. entry.mapId
            .. " has no dedicated event flag and cannot be hidden individually",
          { mapId = entry.mapId, objectEventId = entry.objectEventId }
        )
      end
      return event.eventFlag
    end
  end
  Errors.raise(
    FieldErrors.SCENARIO_OBJECT_NOT_FOUND,
    "map " .. entry.mapId .. " has no object event " .. entry.objectEventId,
    { mapId = entry.mapId, objectEventId = entry.objectEventId }
  )
end

-- fieldDataFor(mapId) returns the compiled `g4-field-map-v3` artifact, so the
-- bootstrap costs a cache read per map rather than a full runtime map load.
-- Returns the applied entries (mapId/objectEventId/eventFlag), which the
-- ROM conformance suite uses to pin the scenario against the real ROM.
function FieldScenario.apply(manifest, eventState, fieldDataFor)
  assert(type(manifest) == "table" and type(manifest.id) == "string", "FieldScenario requires an identified manifest")
  assert(
    eventState and type(fieldDataFor) == "function",
    "FieldScenario requires an event state and a compiled-map reader"
  )
  local applied = {}
  for _, entry in ipairs(manifest.visibility or {}) do
    if entry.op ~= "set_object_event_flag" then
      fail("unsupported scenario operation " .. tostring(entry.op), { op = entry.op })
    end
    local eventFlag = resolveFlag(entry, fieldDataFor)
    eventState:setFlag(eventFlag)
    applied[#applied + 1] = {
      mapId = entry.mapId,
      objectEventId = entry.objectEventId,
      eventFlag = eventFlag,
    }
  end
  return applied
end

-- Resolve an avatar id against the ordered avatar list from the field-actor
-- manifest. Returns its index in that list plus its compiled spriteId, so the
-- scenario, the save schema, and a developer toggle share one source of truth.
function FieldScenario.avatarById(avatars, id)
  assert(type(avatars) == "table", "FieldScenario.avatarById requires the avatar list")
  assert(type(id) == "string", "FieldScenario.avatarById requires an avatar id string")
  for index, avatar in ipairs(avatars) do
    if avatar.id == id then
      return { index = index, id = avatar.id, spriteId = avatar.spriteId }
    end
  end
  Errors.raise(
    FieldErrors.SCENARIO_AVATAR_UNKNOWN,
    "avatar " .. tostring(id) .. " is not one of the compiled player graphics",
    { avatar = id }
  )
end

return FieldScenario
