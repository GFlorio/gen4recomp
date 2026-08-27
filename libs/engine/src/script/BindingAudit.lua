-- Audits the generated field-event binding manifest against the runtime world
-- and normalized field records. Coverage is checked from event identity, then
-- every target is checked against Registry:ids() presence without decoding any
-- deferred script resource.

local Errors = require("libs.errors.src.Errors")
local FieldInteractionResolver = require("libs.engine.src.FieldInteractionResolver")

local BindingAudit = {}

---@class BindingAudit.MissingBinding
---@field kind string
---@field mapId integer
---@field key integer
---@field objectEventId integer?
---@field eventIndex integer?
---@field scriptId integer

---@class BindingAudit.FieldEvents
---@field objects table[]
---@field background table[]
---@field coordinates table[]

local function missingMapData(mapId)
  Errors.raise(
    "SCRIPT_BINDING_AUDIT_MAP_MISSING",
    "required map field data is unavailable or malformed",
    { mapId = mapId }
  )
end

local function requiredIds(value)
  assert(type(value) == "table", "required map ids required")
  local ids = {}
  if #value > 0 then
    for _, mapId in ipairs(value) do
      ids[#ids + 1] = mapId
    end
  else
    for mapId, required in pairs(value) do
      if required then
        ids[#ids + 1] = mapId
      end
    end
  end
  table.sort(ids)
  return ids
end

---@param mapId integer
---@param map table
---@param field table|nil
---@param missing BindingAudit.MissingBinding[]
local function auditFieldEvents(mapId, map, field, missing)
  if
    type(field) ~= "table"
    or field.mapId ~= mapId
    or type(field.events) ~= "table"
    or type(field.events.objects) ~= "table"
    or type(field.events.background) ~= "table"
    or type(field.events.coordinates) ~= "table"
  then
    missingMapData(mapId)
  end
  local fieldRecord = assert(field)
  local events = assert(fieldRecord.events) ---@type BindingAudit.FieldEvents
  for _, event in ipairs(events.objects) do
    if event.scriptId ~= 0 and type(map.objects[event.objectEventId]) ~= "string" then
      missing[#missing + 1] = {
        kind = "object",
        mapId = mapId,
        key = event.objectEventId,
        objectEventId = event.objectEventId,
        scriptId = event.scriptId,
      }
    end
  end
  for _, event in ipairs(events.background) do
    if type(event.hiddenItem) ~= "boolean" then
      missingMapData(mapId)
    elseif FieldInteractionResolver.isHiddenItem(event) then
      if type(map.backgrounds[event.index]) == "string" then
        Errors.raise(
          "SCRIPT_BINDING_AUDIT_HIDDEN_ITEM_BOUND",
          "hidden-item events are declared noninteractive and cannot be bound",
          { mapId = mapId, eventIndex = event.index, scriptId = event.scriptId }
        )
      end
    elseif event.scriptId ~= 0 and type(map.backgrounds[event.index]) ~= "string" then
      missing[#missing + 1] = {
        kind = "background",
        mapId = mapId,
        key = event.index,
        eventIndex = event.index,
        scriptId = event.scriptId,
      }
    end
  end
  for _, event in ipairs(events.coordinates) do
    if event.scriptId ~= 0 and type(map.coordinates[event.index]) ~= "string" then
      missing[#missing + 1] = {
        kind = "coordinate",
        mapId = mapId,
        key = event.index,
        eventIndex = event.index,
        scriptId = event.scriptId,
      }
    end
  end
end

local function auditTargets(manifest, knownScriptIds)
  for mapId, map in pairs(manifest.maps) do
    for section, entries in pairs(map) do
      for eventId, target in pairs(entries) do
        if not knownScriptIds[target] then
          Errors.raise(
            "SCRIPT_BINDING_AUDIT_TARGET_MISSING",
            "binding target is absent from the sealed script registry",
            { mapId = mapId, section = section, eventIndex = eventId, target = target }
          )
        end
      end
    end
  end
end

---@class BindingAuditOptions
---@field loadFieldData fun(mapId: integer): table|nil
---@field requiredMapIds integer[]|table<integer, boolean>
---@field knownScriptIds table<string, boolean>

---@param manifest table validated generated bindings
---@param opts BindingAuditOptions
---@return true
function BindingAudit.check(manifest, opts)
  assert(type(manifest) == "table" and type(manifest.maps) == "table", "bindings manifest required")
  assert(type(opts) == "table", "binding audit options required")
  assert(type(opts.loadFieldData) == "function", "field data loader required")
  assert(type(opts.knownScriptIds) == "table", "known script ids required")

  local missing = {} ---@type BindingAudit.MissingBinding[]
  for _, mapId in ipairs(requiredIds(opts.requiredMapIds)) do
    local map = manifest.maps[mapId]
    if type(map) ~= "table" then
      missingMapData(mapId)
    end
    auditFieldEvents(mapId, map, opts.loadFieldData(mapId), missing)
  end
  if #missing > 0 then
    local context = { missing = missing } ---@type Errors.Context
    ---@cast context Errors.Context
    Errors.raise(
      "SCRIPT_BINDING_AUDIT_INCOMPLETE",
      "interactable events are not bound; every interactable event must be bound or noninteractive",
      context
    )
  end
  auditTargets(manifest, opts.knownScriptIds)
  return true
end

return BindingAudit
