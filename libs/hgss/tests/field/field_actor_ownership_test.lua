-- Field actor owner tests isolate identity, occupancy, and persistence seams.

local Assert = require("tests.support.Assert")
local FieldActorOccupancy = require("libs.hgss.src.actors.FieldActorOccupancy")
local FieldActorPersistence = require("libs.hgss.src.actors.FieldActorPersistence")
local FieldActorStore = require("libs.hgss.src.actors.FieldActorStore")

local T = {}

local function map()
  local value = {
    mapId = 61,
    terrain = {
      plate = function(_, surfaceId)
        return { id = surfaceId, cellKey = "0:0", sourceSurfaceId = surfaceId }
      end,
    },
  }
  ---@cast value RuntimeFieldMap
  return value
end

local function actor(actorId, objectEventId)
  local value = { actorId = actorId, objectEventId = objectEventId }
  ---@cast value FieldActorManager.Actor
  return value
end

function T.store_owns_ordered_identity_and_reverse_indexes()
  local store = FieldActorStore.new()
  local mapEntry = store:createMap(map())
  local first = actor("first", 4)
  local second = actor("second", 9)

  store:addActor(mapEntry, first)
  store:addActor(mapEntry, second)
  Assert.equal(store:getActor(mapEntry, "first"), first)
  Assert.equal(store:getActorByIndex(mapEntry, 9), "second")
  Assert.deepEqual(store:orderedActors(mapEntry), { first, second })

  store:removeActor(mapEntry, first)
  Assert.isNil(store:getActor(mapEntry, "first"))
  Assert.deepEqual(store:orderedActors(mapEntry), { second })
end

function T.occupancy_owns_claim_and_reservation_conflicts()
  local slots = { first = 0, second = 1 }
  local occupancy = FieldActorOccupancy.new({
    runtimeMap = map(),
    managerSlot = function(_, current)
      return slots[current.actorId]
    end,
  })
  local first = actor("first", 4)
  local second = actor("second", 9)
  first.fieldX, first.fieldZ, first.surfaceId, first.solid = 2, 3, 0, true
  second.fieldX, second.fieldZ, second.surfaceId, second.solid = 2, 3, 0, true
  local candidate = { fieldX = 2, fieldZ = 3, surfaceId = 0 }

  occupancy:claim(first, candidate)
  Assert.equal(occupancy:winner(candidate), first)
  occupancy:claim(second, candidate)
  Assert.equal(occupancy:winner(candidate), first)
  Assert.throws(function()
    occupancy:claimExclusive(second, candidate)
  end)
  occupancy:release(first, candidate)
  occupancy:release(second, candidate)
  occupancy:reserve("second", candidate)
  Assert.equal(occupancy:reservation(candidate).actorId, "second")
  Assert.throws(function()
    occupancy:reserve("first", candidate)
  end)
  occupancy:cancelReservation(candidate, "second")
  Assert.isNil(occupancy:reservation(candidate))
end

function T.persistence_translates_actor_state_to_the_existing_save_record()
  local persistence = FieldActorPersistence.new()
  local testActor = {
    actorId = "map:61:object:4",
    mapId = 61,
    objectEventId = 4,
    sourceEvent = { movementType = "wander_around" },
    movementType = "wander_around",
    fieldX = 12,
    fieldZ = 8,
    facing = "west",
    cellKey = "0:0",
    sourceSurfaceId = 12,
  }
  ---@cast testActor FieldActorManager.Actor
  local record = persistence:captureActor(testActor, 3, { phase = "wait" })
  Assert.deepEqual(record, {
    actorId = "map:61:object:4",
    mapId = 61,
    objectEventId = 4,
    sourceMovementType = "wander_around",
    movementType = "wander_around",
    fieldX = 12,
    fieldZ = 8,
    facing = "west",
    controller = { phase = "wait" },
    managerOrder = 3,
    cellKey = "0:0",
    sourceSurfaceId = 12,
  })
  Assert.isTrue(type(persistence.capture) == "function")
  Assert.isTrue(type(persistence.stageRestore) == "function")
end

return { tests = T }
