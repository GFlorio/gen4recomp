-- BindingAudit tests: every interactable event of every bound map must be
-- covered by the bindings manifest at load time; unbound object and
-- background events are rejected loudly, while script-id-zero objects and
-- the type-2 hidden-item background family are noninteractive by the data.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ScriptCache = require("libs.assets.src.ScriptCache")
local BindingAudit = require("libs.engine.src.script.BindingAudit")

local T = {}

---@param code string
---@param fn fun()
---@return Errors.Error
local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
  return err
end

---@param objects table[]
---@param backgrounds table[]
---@param mapId integer?
---@return table
local function fieldData(objects, backgrounds, mapId)
  return { mapId = mapId or 60, events = { objects = objects, background = backgrounds, coordinates = {} } }
end

---@param objectEventId integer
---@param scriptId integer
---@return table
local function objectEvent(objectEventId, scriptId)
  return { objectEventId = objectEventId, scriptId = scriptId, type = 0 }
end

---@param index integer
---@param scriptId integer
---@param eventType integer?
---@return table
local function backgroundEvent(index, scriptId, eventType)
  return { index = index, scriptId = scriptId, type = eventType or 1, hiddenItem = (eventType or 1) == 2 }
end

---@param map table
---@param mapId integer?
---@return table
local function manifestFor(map, mapId)
  return { schema = ScriptCache.BINDINGS_SCHEMA, maps = { [mapId or 60] = map } }
end

---@param manifest table
---@param loadFieldData fun(mapId: integer): table|nil
---@param knownScriptIds table<string, boolean>|nil
---@return true
local function check(manifest, loadFieldData, knownScriptIds)
  if knownScriptIds == nil then
    knownScriptIds = {}
    for _, map in pairs(manifest.maps) do
      for _, entries in pairs(map) do
        for _, target in pairs(entries) do
          knownScriptIds[target] = true
        end
      end
    end
  end
  return BindingAudit.check(manifest, {
    loadFieldData = loadFieldData,
    requiredMapIds = { 60 },
    knownScriptIds = knownScriptIds,
  })
end

local FULL_MAP = {
  objects = {
    [0] = "script.zero",
    [1] = "script.one",
  },
  backgrounds = {
    [0] = "script.bg0",
    [1] = "script.bg1",
  },
  coordinates = {},
}

function T.a_fully_bound_map_passes()
  local ok = check(manifestFor(FULL_MAP), function(mapId)
    Assert.equal(mapId, 60)
    return fieldData({ objectEvent(0, 3), objectEvent(1, 9) }, { backgroundEvent(0, 4), backgroundEvent(1, 7) })
  end)
  Assert.isTrue(ok)
end

function T.an_unbound_interactable_object_event_is_rejected()
  local err = throwsCode("SCRIPT_BINDING_AUDIT_INCOMPLETE", function()
    check(manifestFor(FULL_MAP), function()
      return fieldData({ objectEvent(0, 3), objectEvent(2, 9) }, {})
    end)
  end)
  local missing = assert(err.context.missing) ---@cast missing BindingAudit.MissingBinding[]
  Assert.equal(missing[1].kind, "object")
  Assert.equal(missing[1].key, 2)
  Assert.equal(missing[1].scriptId, 9)
end

function T.an_unbound_interactable_background_event_is_rejected()
  local err = throwsCode("SCRIPT_BINDING_AUDIT_INCOMPLETE", function()
    check(manifestFor(FULL_MAP), function()
      return fieldData({}, { backgroundEvent(0, 4), backgroundEvent(3, 11) })
    end)
  end)
  local missing = assert(err.context.missing) ---@cast missing BindingAudit.MissingBinding[]
  Assert.equal(missing[1].kind, "background")
  Assert.equal(missing[1].key, 3)
end

function T.an_unbound_interactable_coordinate_event_is_rejected()
  local err = throwsCode("SCRIPT_BINDING_AUDIT_INCOMPLETE", function()
    check(manifestFor(FULL_MAP), function()
      return {
        mapId = 60,
        events = {
          objects = {},
          background = {},
          coordinates = {
            { index = 4, scriptId = 17, x = 1, z = 2, width = 1, height = 1 },
          },
        },
      }
    end)
  end)
  local missing = assert(err.context.missing) ---@cast missing BindingAudit.MissingBinding[]
  Assert.equal(missing[1].kind, "coordinate")
  Assert.equal(missing[1].mapId, 60)
  Assert.equal(missing[1].key, 4)
  Assert.equal(missing[1].scriptId, 17)
end

function T.script_id_zero_objects_are_noninteractive()
  local ok = check(manifestFor(FULL_MAP), function()
    return fieldData({ objectEvent(0, 3), objectEvent(9, 0) }, {})
  end)
  Assert.isTrue(ok)
end

function T.type_two_background_events_are_noninteractive()
  local ok = check(manifestFor(FULL_MAP), function()
    return fieldData({}, { backgroundEvent(0, 4), backgroundEvent(7, 8000, 2) })
  end)
  Assert.isTrue(ok)
end

-- The hidden-item family is declared noninteractive, so a manifest
-- binding for one is a dead binding the resolver can never dispatch; the
-- audit rejects it loudly instead of accepting it silently.
function T.binding_a_hidden_item_event_is_rejected()
  local manifest = manifestFor({
    objects = {},
    backgrounds = { [0] = "script.bg0", [7] = "vanilla.hiddenitem.8000" },
  })
  local err = throwsCode("SCRIPT_BINDING_AUDIT_HIDDEN_ITEM_BOUND", function()
    check(manifest, function()
      return fieldData({}, { backgroundEvent(0, 4), backgroundEvent(7, 8000, 2) })
    end)
  end)
  Assert.equal(err.context.mapId, 60)
  Assert.equal(err.context.eventIndex, 7)
end

function T.a_manifest_map_with_no_field_data_is_rejected()
  throwsCode("SCRIPT_BINDING_AUDIT_MAP_MISSING", function()
    check(manifestFor(FULL_MAP), function()
      return nil
    end)
  end)
end

-- A malformed generated record (present but without the events table, or
-- without a required event collection) is rejected as missing field data,
-- never read as an empty event list.
function T.a_field_record_without_events_is_rejected()
  throwsCode("SCRIPT_BINDING_AUDIT_MAP_MISSING", function()
    check(manifestFor(FULL_MAP), function()
      return { mapId = 60 }
    end)
  end)
end

-- A record for a different map would audit the wrong events: the pairing of
-- manifest and field data must be exact.
function T.a_field_record_for_a_different_map_is_rejected()
  throwsCode("SCRIPT_BINDING_AUDIT_MAP_MISSING", function()
    check(manifestFor(FULL_MAP), function()
      return { mapId = 61, events = { objects = {}, background = {}, coordinates = {} } }
    end)
  end)
end

function T.a_field_record_without_event_collections_is_rejected()
  throwsCode("SCRIPT_BINDING_AUDIT_MAP_MISSING", function()
    check(manifestFor(FULL_MAP), function()
      return { events = {} }
    end)
  end)
end

---@param fieldRecords table<integer, table>
---@param requiredMapIds integer[]
---@param knownScriptIds table<string, boolean>
---@param loaderCalls table<integer, integer>
---@return BindingAuditOptions
local function auditOptions(fieldRecords, requiredMapIds, knownScriptIds, loaderCalls)
  return {
    requiredMapIds = requiredMapIds,
    knownScriptIds = knownScriptIds,
    loadFieldData = function(mapId)
      loaderCalls[mapId] = (loaderCalls[mapId] or 0) + 1
      return fieldRecords[mapId]
    end,
  }
end

---@param code string
---@param fn fun()
---@return Errors.Error
local function targetAuditError(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(
    Errors.is(err),
    "binding audit must expose a structured required-map/target error, got " .. tostring(err)
  )
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
  return err
end

-- Runtime maps are required independently of which maps happen to be listed
-- in the generated manifest. A stale manifest cannot narrow the audited world.
function T.a_required_runtime_map_and_event_are_audited()
  local fields = {
    [60] = fieldData({}, {}),
  }
  local calls = {}
  local options = auditOptions(fields, { 60, 33 }, {}, calls)
  local err = targetAuditError("SCRIPT_BINDING_AUDIT_MAP_MISSING", function()
    BindingAudit.check(manifestFor({ objects = {}, backgrounds = {}, coordinates = {} }), options)
  end)
  Assert.equal(err.context.mapId, 33)

  fields[33] = fieldData({ objectEvent(4, 7) }, {}, 33)
  calls = {}
  options = auditOptions(fields, { 33 }, {}, calls)
  err = targetAuditError("SCRIPT_BINDING_AUDIT_INCOMPLETE", function()
    BindingAudit.check(manifestFor({ objects = {}, backgrounds = {}, coordinates = {} }, 33), options)
  end)
  local missing = err.context.missing
  ---@cast missing BindingAudit.MissingBinding[]
  local missingObject = assert(missing[1])
  Assert.equal(missingObject.kind, "object")
  Assert.equal(missingObject.mapId, 33)
  Assert.equal(missingObject.objectEventId, 4)
  Assert.equal(missingObject.key, 4)
end

-- Target presence is checked from a registry ID set. The audit never needs to
-- decode a deferred generated resource to prove that a present target exists.
function T.a_missing_target_fails_but_a_deferred_present_target_stays_lazy()
  local fields = {
    [60] = fieldData({ objectEvent(0, 1) }, {}),
  }
  local calls = {}
  local options = auditOptions(fields, { 60 }, {}, calls)
  local manifest = manifestFor({ objects = { [0] = "vanilla.missing" }, backgrounds = {}, coordinates = {} })
  local err = targetAuditError("SCRIPT_BINDING_AUDIT_TARGET_MISSING", function()
    BindingAudit.check(manifest, options)
  end)
  Assert.equal(err.context.mapId, 60)
  Assert.equal(err.context.target, "vanilla.missing")

  calls = {}
  options = auditOptions(fields, { 60 }, { ["vanilla.deferred"] = true }, calls)
  local deferred = manifestFor({ objects = { [0] = "vanilla.deferred" }, backgrounds = {}, coordinates = {} })
  Assert.isTrue(BindingAudit.check(deferred, options))
  Assert.equal(calls[60], 1, "the field record is read once for event coverage")
end

return { tests = T }
