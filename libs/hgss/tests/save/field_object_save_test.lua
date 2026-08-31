-- Field-object save records are a strict, source-identity keyed HGSS bucket.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldObjectSave = require("libs.hgss.src.save.FieldObjectSave")

local T = {}

local function actor(overrides)
  local result = {
    actorId = "map:60:object:7",
    mapId = 60,
    objectEventId = 7,
    sourceMovementType = "wander_around",
    movementType = "wander_around",
    fieldX = 12,
    fieldZ = 14,
    cellKey = "0:0",
    sourceSurfaceId = 3,
    facing = "east",
    controller = {
      kind = "wander",
      timer = 16,
      sequenceIndex = 1,
      rotationIndex = 1,
      shuttleDirection = "east",
      blocked = false,
    },
  } ---@type table
  for key, value in pairs(overrides or {}) do
    rawset(result, key, value)
  end
  return result
end

local function record(overrides)
  local result = {
    schema = FieldObjectSave.SCHEMA,
    rng = { state = 7, calls = 3 },
    actors = { ["map:60:object:7"] = actor() },
  } ---@type table
  for key, value in pairs(overrides or {}) do
    rawset(result, key, value)
  end
  return result
end

function T.legacy_empty_bucket_is_accepted()
  local valid, err = FieldObjectSave.validate({})
  Assert.deepEqual({}, assert(valid))
  Assert.isNil(err)
end

function T.current_record_is_canonicalized_without_aliases()
  local input = record()
  local valid = assert(FieldObjectSave.validate(input))
  Assert.deepEqual(input, valid)
  Assert.isFalse(input == valid)
  Assert.isFalse(input.actors["map:60:object:7"] == valid.actors["map:60:object:7"])
end

function T.unknown_fields_and_malformed_progress_are_rejected()
  local cases = {
    record({ extra = true }),
    record({ rng = { state = 7, calls = 3, extra = true } }),
    record({ actors = { ["map:60:object:7"] = actor({ extra = true }) } }),
    record({
      actors = {
        ["map:60:object:7"] = actor({
          action = {
            owner = "autonomous",
            kind = "walk",
            direction = "east",
            start = { fieldX = 12, fieldZ = 14, cellKey = "0:0", sourceSurfaceId = 3 },
            destination = { fieldX = 13, fieldZ = 14, cellKey = "0:0", sourceSurfaceId = 3 },
            durationTicks = 8,
            progressTicks = 9,
          },
        }),
      },
    }),
  }
  for _, candidate in ipairs(cases) do
    local valid, err = FieldObjectSave.validate(candidate)
    Assert.isNil(valid)
    Assert.isTrue(Errors.is(err))
  end
end

function T.source_surface_identity_is_required_for_actors_and_actions()
  local invalidActor = actor()
  invalidActor.cellKey = nil
  local valid, err = FieldObjectSave.validate(record({ actors = { [invalidActor.actorId] = invalidActor } }))
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))

  local invalidAction = actor({
    action = {
      owner = "autonomous",
      kind = "walk",
      direction = "east",
      start = { fieldX = 12, fieldZ = 14, cellKey = "0:0", sourceSurfaceId = 3 },
      destination = { fieldX = 13, fieldZ = 14, cellKey = nil, sourceSurfaceId = 3 },
      durationTicks = 8,
      progressTicks = 1,
    },
  })
  valid, err = FieldObjectSave.validate(record({ actors = { [invalidAction.actorId] = invalidAction } }))
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))
end

return { tests = T }
