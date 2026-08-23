-- Load-time binding audit : every interactable event of every
-- bound map must be covered by the bindings manifest. An object event with a
-- script id is interactable (the resolver starts the bound script); a
-- background event with a script id is interactable unless it is the type-2
-- hidden-item family the resolver declares noninteractive. Events whose
-- script id is 0 are satisfied by the canonical inert runtime script. The
-- hidden-item declaration is shared with the
-- resolver (`FieldInteractionResolver.isHiddenItem`): exempting those events
-- and rejecting manifest bindings for them keeps the two sides of the
-- declaration from drifting -- a bound hidden item could never dispatch. The
-- audit runs at build/load, never at runtime: an unbound interactable event
-- is a composition error, not a fallback to look for later. Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldInteractionResolver = require("libs.engine.src.FieldInteractionResolver")
local FieldObjectActor = require("libs.engine.src.FieldObjectActor")

local BindingAudit = {}

---@class BindingAuditFailure
---@field kind string
---@field mapId integer
---@field key string
---@field scriptId integer

local function missingMapData(mapId)
  Errors.raise(
    "SCRIPT_BINDING_AUDIT_MAP_MISSING",
    "the bindings manifest names a map with no field data",
    { mapId = mapId }
  )
end

-- Validate the manifest against the compiled field data. `loadFieldData`
-- resolves a map id to its compiled field record (fieldData.events.objects /
-- .background with the zone-event script ids), or nil when the map has no
-- compiled data. A present record must carry the map id and the events table
-- with both event collections: generated schemas are strict, so a malformed
-- or mismatched record is rejected as missing field data, never read as an
-- empty event list. Raises SCRIPT_BINDING_AUDIT_INCOMPLETE naming every
-- interactable event the manifest does not bind.
---@param manifest table
---@param loadFieldData function
---@return true
function BindingAudit.check(manifest, loadFieldData)
  assert(type(manifest) == "table", "bindings manifest required")
  assert(type(loadFieldData) == "function", "field data loader required")
  local missing = {}
  for mapId, map in pairs(manifest.maps or {}) do
    local field = loadFieldData(mapId)
    if type(field) ~= "table" or type(field.events) ~= "table" or field.mapId ~= mapId then
      missingMapData(mapId)
    end
    local fieldEvents = field.events
    if
      type(fieldEvents.objects) ~= "table"
      or type(fieldEvents.background) ~= "table"
      or type(fieldEvents.coordinates) ~= "table"
    then
      missingMapData(mapId)
    end
    for _, event in ipairs(fieldEvents.objects) do
      if event.scriptId ~= 0 then
        local key = FieldObjectActor.actorId(mapId, event.objectEventId)
        if type(map.objects[key]) ~= "string" then
          missing[#missing + 1] = { kind = "object", mapId = mapId, key = key, scriptId = event.scriptId }
        end
      end
    end
    for _, event in ipairs(fieldEvents.background) do
      if FieldInteractionResolver.isHiddenItem(event) then
        -- The hidden-item family is declared noninteractive: a manifest
        -- binding for it is a dead binding the resolver can never dispatch,
        -- so it is rejected loudly instead of accepted silently.
        local key = event.index
        if type(map.backgrounds[key]) == "string" then
          Errors.raise(
            "SCRIPT_BINDING_AUDIT_HIDDEN_ITEM_BOUND",
            "hidden-item events are declared noninteractive and cannot be bound",
            { mapId = mapId, eventIndex = key, scriptId = event.scriptId }
          )
        end
      elseif event.scriptId ~= 0 then
        local key = string.format("map:%d:background:%d", mapId, event.index)
        if type(map.backgrounds[event.index]) ~= "string" then
          missing[#missing + 1] = { kind = "background", mapId = mapId, key = key, scriptId = event.scriptId }
        end
      end
    end
    for _, event in ipairs(fieldEvents.coordinates) do
      if event.scriptId ~= 0 then
        local key = string.format("map:%d:coordinate:%d", mapId, event.index)
        if type(map.coordinates[event.index]) ~= "string" then
          missing[#missing + 1] = { kind = "coordinate", mapId = mapId, key = key, scriptId = event.scriptId }
        end
      end
    end
  end
  if #missing > 0 then
    Errors.raise(
      "SCRIPT_BINDING_AUDIT_INCOMPLETE",
      "interactable events are not bound; every interactable event must be bound or noninteractive",
      { missing = missing }
    )
  end
  return true
end

return BindingAudit
