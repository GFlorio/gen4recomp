-- FieldScenario tests freeze the bootstrap contract: a manifest names objects by
-- stable identity, the numeric ROM flag is resolved from compiled map data, and
-- an unresolvable entry fails loudly instead of hiding the wrong actor.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldScenario = require("libs.engine.src.FieldScenario")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

local FIELD_DATA = {
  [61] = { events = { objects = {
    { objectEventId = 0, eventFlag = 401 },
    { objectEventId = 1, eventFlag = 413 },
    { objectEventId = 2, eventFlag = 0 },
  } } },
}

local function fieldDataFor(mapId) return FIELD_DATA[mapId] end

local function manifest(visibility)
  return { id = "test-scenario", visibility = visibility }
end

function T.object_identity_resolves_to_the_numeric_rom_flag()
  local state = FieldEventState.new()
  local applied = FieldScenario.apply(manifest({
    { op = "set_object_event_flag", mapId = 61, objectEventId = 1 },
  }), state, fieldDataFor)
  Assert.isTrue(state:isFlagSet(413))
  Assert.isFalse(state:isFlagSet(401))
  Assert.deepEqual(applied, { { mapId = 61, objectEventId = 1, eventFlag = 413 } })
end

function T.unknown_object_identity_is_fatal()
  throwsCode("SCENARIO_OBJECT_NOT_FOUND", function()
    FieldScenario.apply(manifest({
      { op = "set_object_event_flag", mapId = 61, objectEventId = 9 },
    }), FieldEventState.new(), fieldDataFor)
  end)
end

function T.unknown_map_is_fatal()
  throwsCode("SCENARIO_FLAG_RESOLUTION_FAILED", function()
    FieldScenario.apply(manifest({
      { op = "set_object_event_flag", mapId = 60, objectEventId = 0 },
    }), FieldEventState.new(), fieldDataFor)
  end)
end

function T.flag_zero_cannot_hide_a_single_object()
  -- Flag 0 is shared by every unguarded object, so setting it would hide them
  -- all. That is a manifest authoring error, not a runtime special case.
  throwsCode("SCENARIO_FLAG_RESOLUTION_FAILED", function()
    FieldScenario.apply(manifest({
      { op = "set_object_event_flag", mapId = 61, objectEventId = 2 },
    }), FieldEventState.new(), fieldDataFor)
  end)
end

function T.unknown_operations_are_fatal()
  throwsCode("SCENARIO_FLAG_RESOLUTION_FAILED", function()
    FieldScenario.apply(manifest({ { op = "teleport", mapId = 61 } }),
      FieldEventState.new(), fieldDataFor)
  end)
end

local AVATARS = { { id = "hero", spriteId = 0 }, { id = "heroine", spriteId = 97 } }

function T.resolves_an_explicit_avatar_id_against_the_manifest_order()
  local resolved = FieldScenario.avatarById(AVATARS, "hero")
  Assert.equal(resolved.index, 1)
  Assert.equal(resolved.id, "hero")
  Assert.equal(resolved.spriteId, 0)
  local heroine = FieldScenario.avatarById(AVATARS, "heroine")
  Assert.equal(heroine.index, 2)
  Assert.equal(heroine.spriteId, 97)
end

function T.an_unknown_avatar_is_fatal()
  throwsCode("SCENARIO_AVATAR_UNKNOWN", function()
    FieldScenario.avatarById(AVATARS, "rival")
  end)
end

function T.the_shipped_demo_manifest_is_well_formed()
  local demo = require("data.manifests.field_scenario")
  local actors = require("data.manifests.field_actors")
  Assert.equal(demo.id, "pre-script-demo-v1")
  Assert.notNil(FieldScenario.avatarById(actors.avatars, demo.avatar),
    "the demo avatar must name one of the compiled player graphics")
  Assert.isTrue(#demo.visibility > 0)
  for _, entry in ipairs(demo.visibility) do
    Assert.equal(entry.op, "set_object_event_flag")
    Assert.equal(type(entry.mapId), "number")
    Assert.equal(type(entry.objectEventId), "number")
  end
end

return T
