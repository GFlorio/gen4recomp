-- BindingAudit tests: every interactable event of every bound map must be
-- covered by the bindings manifest at load time; unbound object and
-- background events are rejected loudly, while script-id-zero objects and
-- the type-2 hidden-item background family are noninteractive by the data.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local BindingAudit = require("libs.engine.src.script.BindingAudit")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
  return err
end

local function fieldData(objects, backgrounds)
  return { mapId = 60, events = { objects = objects, background = backgrounds, coordinates = {} } }
end

local function objectEvent(objectEventId, scriptId)
  return { objectEventId = objectEventId, scriptId = scriptId, type = 0 }
end

local function backgroundEvent(index, scriptId, eventType)
  return { index = index, scriptId = scriptId, type = eventType or 1 }
end

local function manifestFor(map)
  return { maps = { [60] = map } }
end

local FULL_MAP = {
  objects = {
    ["map:60:object:0"] = "script.zero",
    ["map:60:object:1"] = "script.one",
  },
  backgrounds = {
    [0] = "script.bg0",
    [1] = "script.bg1",
  },
  coordinates = {},
}

function T.a_fully_bound_map_passes()
  local ok = BindingAudit.check(manifestFor(FULL_MAP), function(mapId)
    Assert.equal(mapId, 60)
    return fieldData({ objectEvent(0, 3), objectEvent(1, 9) }, { backgroundEvent(0, 4), backgroundEvent(1, 7) })
  end)
  Assert.isTrue(ok)
end

function T.an_unbound_interactable_object_event_is_rejected()
  local err = throwsCode("SCRIPT_BINDING_AUDIT_INCOMPLETE", function()
    BindingAudit.check(manifestFor(FULL_MAP), function()
      return fieldData({ objectEvent(0, 3), objectEvent(2, 9) }, {})
    end)
  end)
  Assert.equal(err.context.missing[1].kind, "object")
  Assert.equal(err.context.missing[1].key, "map:60:object:2")
  Assert.equal(err.context.missing[1].scriptId, 9)
end

function T.an_unbound_interactable_background_event_is_rejected()
  local err = throwsCode("SCRIPT_BINDING_AUDIT_INCOMPLETE", function()
    BindingAudit.check(manifestFor(FULL_MAP), function()
      return fieldData({}, { backgroundEvent(0, 4), backgroundEvent(3, 11) })
    end)
  end)
  Assert.equal(err.context.missing[1].kind, "background")
  Assert.equal(err.context.missing[1].key, "map:60:background:3")
end

function T.an_unbound_interactable_coordinate_event_is_rejected()
  local err = throwsCode("SCRIPT_BINDING_AUDIT_INCOMPLETE", function()
    BindingAudit.check(manifestFor(FULL_MAP), function()
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
  Assert.equal(err.context.missing[1].kind, "coordinate")
  Assert.equal(err.context.missing[1].mapId, 60)
  Assert.equal(err.context.missing[1].key, "map:60:coordinate:4")
  Assert.equal(err.context.missing[1].scriptId, 17)
end

function T.script_id_zero_objects_are_noninteractive()
  local ok = BindingAudit.check(manifestFor(FULL_MAP), function()
    return fieldData({ objectEvent(0, 3), objectEvent(9, 0) }, {})
  end)
  Assert.isTrue(ok)
end

function T.type_two_background_events_are_noninteractive()
  local ok = BindingAudit.check(manifestFor(FULL_MAP), function()
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
    BindingAudit.check(manifest, function()
      return fieldData({}, { backgroundEvent(0, 4), backgroundEvent(7, 8000, 2) })
    end)
  end)
  Assert.equal(err.context.mapId, 60)
  Assert.equal(err.context.eventIndex, 7)
end

function T.a_manifest_map_with_no_field_data_is_rejected()
  throwsCode("SCRIPT_BINDING_AUDIT_MAP_MISSING", function()
    BindingAudit.check(manifestFor(FULL_MAP), function()
      return nil
    end)
  end)
end

-- A malformed generated record (present but without the events table, or
-- without a required event collection) is rejected as missing field data,
-- never read as an empty event list.
function T.a_field_record_without_events_is_rejected()
  throwsCode("SCRIPT_BINDING_AUDIT_MAP_MISSING", function()
    BindingAudit.check(manifestFor(FULL_MAP), function()
      return { mapId = 60 }
    end)
  end)
end

-- A record for a different map would audit the wrong events: the pairing of
-- manifest and field data must be exact.
function T.a_field_record_for_a_different_map_is_rejected()
  throwsCode("SCRIPT_BINDING_AUDIT_MAP_MISSING", function()
    BindingAudit.check(manifestFor(FULL_MAP), function()
      return { mapId = 61, events = { objects = {}, background = {}, coordinates = {} } }
    end)
  end)
end

function T.a_field_record_without_event_collections_is_rejected()
  throwsCode("SCRIPT_BINDING_AUDIT_MAP_MISSING", function()
    BindingAudit.check(manifestFor(FULL_MAP), function()
      return { events = {} }
    end)
  end)
end

return { tests = T }
