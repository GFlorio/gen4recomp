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
    managerOrder = 0,
    controller = {
      kind = "wander",
      timer = 16,
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
      progressTicks = 1,
    },
  })
  valid, err = FieldObjectSave.validate(record({ actors = { [invalidAction.actorId] = invalidAction } }))
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))
end

function T.malformed_manager_order_is_rejected()
  local missing = actor()
  missing.managerOrder = nil
  local valid, err = FieldObjectSave.validate(record({ actors = { [missing.actorId] = missing } }))
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))

  local negative = actor({ managerOrder = -1 })
  valid, err = FieldObjectSave.validate(record({ actors = { [negative.actorId] = negative } }))
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))

  local fractional = actor({ managerOrder = 0.5 })
  valid, err = FieldObjectSave.validate(record({ actors = { [fractional.actorId] = fractional } }))
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))

  local duplicate = {
    schema = FieldObjectSave.SCHEMA,
    rng = { state = 7, calls = 3 },
    actors = {
      ["map:60:object:7"] = actor({ actorId = "map:60:object:7", objectEventId = 7, mapId = 60, managerOrder = 0 }),
      ["map:60:object:8"] = actor({ actorId = "map:60:object:8", objectEventId = 8, mapId = 60, managerOrder = 0 }),
    },
  }
  valid, err = FieldObjectSave.validate(duplicate)
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))

  local gap = {
    schema = FieldObjectSave.SCHEMA,
    rng = { state = 7, calls = 3 },
    actors = {
      ["map:60:object:7"] = actor({ actorId = "map:60:object:7", objectEventId = 7, mapId = 60, managerOrder = 0 }),
      ["map:60:object:8"] = actor({ actorId = "map:60:object:8", objectEventId = 8, mapId = 60, managerOrder = 2 }),
    },
  }
  valid, err = FieldObjectSave.validate(gap)
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))

  local perMapZero = {
    schema = FieldObjectSave.SCHEMA,
    rng = { state = 7, calls = 3 },
    actors = {
      ["map:60:object:7"] = actor({ actorId = "map:60:object:7", mapId = 60, objectEventId = 7, managerOrder = 0 }),
      ["map:61:object:7"] = actor({ actorId = "map:61:object:7", mapId = 61, objectEventId = 7, managerOrder = 0 }),
    },
  }
  valid, err = FieldObjectSave.validate(perMapZero)
  Assert.notNil(valid, tostring(err))
  local validRecord = assert(valid)
  local actors = assert(validRecord.actors)
  Assert.equal(assert(actors["map:60:object:7"]).managerOrder, 0)
  Assert.equal(assert(actors["map:61:object:7"]).managerOrder, 0)

  local recordToValidate = record()
  valid, err = FieldObjectSave.validate(recordToValidate)
  Assert.notNil(valid, tostring(err))
  local roundTripRecord = assert(valid)
  local validActors = assert(roundTripRecord.actors)
  Assert.equal(assert(validActors["map:60:object:7"]).managerOrder, 0)
end

return { tests = T }
