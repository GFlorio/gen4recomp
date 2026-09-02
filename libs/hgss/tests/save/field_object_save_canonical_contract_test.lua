-- Protects the executable canonical shape of field-object snapshots.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldObjectSave = require("libs.hgss.src.save.FieldObjectSave")

local T = {}

local function actor(overrides)
  local result = {
    actorId = "map:60:object:7",
    mapId = 60,
    objectEventId = 7,
    sourceMovementType = "walk_north_east_west_south",
    movementType = "walk_north_east_west_south",
    fieldX = 12,
    fieldZ = 14,
    cellKey = "0:0",
    sourceSurfaceId = 3,
    facing = "east",
    managerOrder = 0,
    controller = { kind = "pattern", timer = 0, sequenceIndex = 1 },
  } ---@type table
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

local function record(actorRecord)
  return {
    schema = FieldObjectSave.SCHEMA,
    rng = { state = 7, calls = 3 },
    actors = { [actorRecord.actorId] = actorRecord },
  }
end

function T.profile_index_and_removed_controller_state_are_rejected()
  local invalidIndex = actor()
  invalidIndex.controller.sequenceIndex = 999
  local valid, err = FieldObjectSave.validate(record(invalidIndex))
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))

  local removedState = actor()
  removedState.controller.blocked = false
  valid, err = FieldObjectSave.validate(record(removedState))
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))
end

function T.nonresident_actor_may_omit_the_complete_stable_identity_pair()
  local logicalActor = actor()
  logicalActor.cellKey = nil
  logicalActor.sourceSurfaceId = nil
  local valid, err = FieldObjectSave.validate(record(logicalActor))
  Assert.notNil(valid)
  Assert.isNil(err)
end

function T.canonical_active_action_omits_duration_and_uses_progress_only()
  local movingActor = actor({
    action = {
      owner = "autonomous",
      kind = "walk",
      direction = "east",
      start = { fieldX = 12, fieldZ = 14, cellKey = "0:0", sourceSurfaceId = 3 },
      destination = { fieldX = 13, fieldZ = 14, cellKey = "0:0", sourceSurfaceId = 3 },
      progressTicks = 1,
    },
  })
  local valid, err = FieldObjectSave.validate(record(movingActor))
  Assert.notNil(valid)
  Assert.isNil(err)
end

return { tests = T }
