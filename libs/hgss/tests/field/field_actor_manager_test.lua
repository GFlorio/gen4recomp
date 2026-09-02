-- FieldActorManager tests freeze the object-actor lifecycle: flag visibility,
-- surface resolution, the occupancy index, idempotent map entry, and balanced
-- visual acquire/release.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.hgss.src.field.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldObjectActor = require("libs.hgss.src.field.FieldObjectActor")
local FieldObjectSave = require("libs.hgss.src.save.FieldObjectSave")
local FieldPlayer = require("libs.hgss.src.field.FieldPlayer")
local FieldRegion = require("libs.hgss.src.field.FieldRegion")
local TerrainSurface = require("libs.hgss.src.field.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

---@class FieldActorManagerTest.Assets
---@field references table<integer, integer>
---@field knows fun(self: FieldActorManagerTest.Assets, spriteId: integer): boolean
---@field acquire fun(self: FieldActorManagerTest.Assets, spriteId: integer): table
---@field release fun(self: FieldActorManagerTest.Assets, spriteId: integer)
---@field total fun(self: FieldActorManagerTest.Assets): integer
local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

-- Plate 0 is the ground; plate 1 is stacked four units above it on x >= 8, so
-- surface selection and same-x/z different-surface occupancy are testable.
-- Plate 2 duplicates plate 0's height over x 20..24 to force an exact tie.
local function terrain()
  return TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
      {
        id = 1,
        minX = 8,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 4,
        slopeClass = "flat",
      },
      {
        id = 2,
        minX = 20,
        minZ = 0,
        maxX = 24,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
end

local function object(overrides)
  local event = {
    index = 0,
    objectEventId = 0,
    spriteId = 99,
    movementType = "stationary",
    type = 0,
    eventFlag = 0,
    scriptId = 1,
    facingDirection = "south",
    facingDirectionRaw = 1,
    param0 = 0,
    param1 = 0,
    param2 = 0,
    xRange = 0,
    yRange = 0,
    x = 2,
    z = 3,
    y = 0,
  } --[[@as table<string, unknown>]]
  for key, value in pairs(overrides or {}) do
    rawset(event, key, value)
  end
  return event --[[@as FieldActorEvent]]
end

local function rawObjectEventY(runtimeTileY)
  return runtimeTileY * 16 * 4096
end

local function runtimeMap(objects, mapId)
  local map = {
    mapId = mapId or 61,
    mapSection = "test-section",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 40 and z >= 0 and z < 32
      end,
    },
    terrain = terrain(),
    mapSymbol = "test-map",
    sceneRuntime = nil,
    scene = {},
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 4,
    fieldData = { events = { objects = objects, background = {}, warps = {}, coordinates = {} } },
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
  return map
end

local function sourceRegionMap(objects, surfaceIdBase, sourceTerrain)
  local map = runtimeMap(objects)
  local region = FieldRegion.new(map.collision, sourceTerrain, {}, "0:0", surfaceIdBase)
  map.collision = region.collision
  map.terrain = region.terrain
  map.fieldRegion = region
  return map
end

local function flatPlate(id, minX, maxX, distance)
  return {
    id = id,
    minX = minX,
    minZ = 0,
    maxX = maxX,
    maxZ = 32,
    normal = { x = 0, y = 1, z = 0 },
    distance = distance,
    slopeClass = "flat",
  }
end

-- Stands in for FieldActorAssetProvider: same acquire/release/knows contract,
-- with a reference tally so leaks are visible to the tests.
local function fakeAssets(known)
  local assets = {
    references = {},
    knows = function(_, spriteId)
      return known[spriteId] == true
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function(self, spriteId)
      local count = self.references[spriteId] or 0
      assert(count > 0, "unbalanced release of spriteId " .. spriteId)
      self.references[spriteId] = count - 1
    end,
    total = function(self)
      local sum = 0
      for _, count in pairs(self.references) do
        sum = sum + count
      end
      return sum
    end,
  } --[[@as FieldActorManagerTest.Assets]]
  return assets
end

local function manager(objects, opts)
  opts = opts or {}
  local assets = opts.assets or fakeAssets({ [99] = true, [34] = true, [29] = true, [0] = true })
  local eventState = opts.eventState or FieldEventState.new()
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY, autonomyRng = opts.autonomyRng })
  local map = opts.map or runtimeMap(objects)
  mgr:enterMap(map, eventState, opts.restoredObjects)
  return mgr, eventState, assets, map
end

local function capturedUpperSnapshot()
  local objects = { object({ x = 9, z = 3 }) }
  local map = sourceRegionMap(objects, 0, terrain())
  local mgr = manager(objects, { map = map })
  mgr:setPosition("map:61:object:0", { fieldX = 9, fieldZ = 3, worldY = 4 })

  local captured = mgr:captureObjects()
  local validated, validationErr = FieldObjectSave.validate(captured)
  Assert.notNil(validated, tostring(validationErr))
  mgr:dispose()
  return assert(validated)
end

local function candidate(fieldX, fieldZ, surfaceId)
  return { fieldX = fieldX, fieldZ = fieldZ, surfaceId = surfaceId }
end

local function getAt(mgr, mapId, fieldX, fieldZ, surfaceId)
  return mgr:getAt(mapId, candidate(fieldX, fieldZ, surfaceId))
end

local function isOccupied(mgr, mapId, fieldX, fieldZ, surfaceId, exceptActorId)
  return mgr:isOccupied(mapId, candidate(fieldX, fieldZ, surfaceId), exceptActorId)
end

local function forceAutonomy(mgr, direction, onStep)
  mgr.autonomy = {
    rng = {},
    profiles = {},
    states = {},
    isOrdinary = function()
      return true
    end,
    detach = function() end,
    applyPendingMovementType = function() end,
    state = function(_, actorId)
      return {
        movementType = assert(mgr:getById(actorId)).movementType,
        profile = { kind = "wander" },
      }
    end,
    step = function(_, actorId, capability)
      if onStep then
        onStep(capability)
      end
      capability:walk(actorId, direction)
    end,
  }
end

local function deterministicRng(values)
  local index = 0
  return {
    nextInt = function(_, maximum)
      index = index + 1
      local value = assert(values[index], "deterministic autonomy roll is missing")
      Assert.isTrue(value >= 0 and value < maximum, "deterministic autonomy roll must fit its bound")
      return value
    end,
  }
end

local function stableCandidate(fieldX, fieldZ, surfaceId, cellKey, sourceSurfaceId)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    cellKey = cellKey,
    sourceSurfaceId = sourceSurfaceId,
  }
end

function T.visible_objects_become_actors_and_flagged_ones_do_not()
  local eventState = FieldEventState.new({ flags = { [413] = true } })
  local mgr = manager({
    object({ objectEventId = 0, eventFlag = 401 }),
    object({ objectEventId = 1, spriteId = 34, eventFlag = 413, x = 4 }),
  }, { eventState = eventState })
  Assert.notNil(mgr:getById("map:61:object:0"))
  Assert.isNil(mgr:getById("map:61:object:1"))
  Assert.equal(#mgr:drawRecords(), 1)
end

function T.legacy_empty_object_bucket_keeps_source_actor_initialization()
  local mgr = manager({ object({}) }, { restoredObjects = {} })
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.equal(actor.fieldX, 2)
  Assert.equal(actor.fieldZ, 3)
  Assert.equal(actor.movementType, "stationary")
  mgr:dispose()
end

function T.restored_effective_movement_type_is_applied_to_the_actor()
  local actorId = "map:61:object:0"
  local mgr = manager({ object({ movementType = "stationary" }) }, {
    restoredObjects = {
      schema = "g4-field-objects-v1",
      rng = { state = 7, calls = 0 },
      actors = {
        [actorId] = {
          actorId = actorId,
          mapId = 61,
          objectEventId = 0,
          sourceMovementType = "stationary",
          movementType = "wander_north_south",
          fieldX = 2,
          fieldZ = 3,
          facing = "south",
          controller = { kind = "wander", timer = 4 },
        },
      },
    },
  })
  local actor = assert(mgr:getById(actorId))
  Assert.equal(actor.movementType, "wander_north_south")
  Assert.equal(mgr.autonomy:state(actorId).movementType, "wander_north_south")
  mgr:dispose()
end

function T.nonresident_restore_is_explicit_and_not_replayed_on_reentry()
  local map = runtimeMap({ object({ x = 2, z = 3 }) })
  map.coverage = {
    containsGlobal = function(_, fieldX)
      return fieldX < 10
    end,
  }
  map.terrain = TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 64,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
  local actorId = "map:61:object:0"
  local snapshot = {
    schema = "g4-field-objects-v1",
    rng = { state = 7, calls = 0 },
    actors = {
      [actorId] = {
        actorId = actorId,
        mapId = 61,
        objectEventId = 0,
        sourceMovementType = "stationary",
        movementType = "wander_north_south",
        fieldX = 34,
        fieldZ = 3,
        facing = "north",
        controller = { kind = "wander", timer = 0 },
      },
    },
  }
  local mgr = FieldActorManager.new({ assets = fakeAssets({ [99] = true }), policy = POLICY })
  local eventState = FieldEventState.new()

  mgr:enterMap(map, eventState, snapshot)
  local actor = assert(mgr:getById(actorId))
  Assert.equal(actor.fieldX, 34)
  Assert.equal(actor.facing, "north")
  Assert.equal(actor.movementType, "wander_north_south")
  Assert.isFalse(actor.resident)
  Assert.isNil(actor.surfaceId)
  local initialRngCalls = mgr.autonomy:captureRng().calls
  local stepped, stepError = pcall(function()
    mgr:step(1)
    mgr:step(2)
  end)
  Assert.isTrue(stepped, tostring(stepError))
  Assert.equal(mgr.autonomy:captureRng().calls, initialRngCalls, "a nonresident actor must not advance autonomy")
  Assert.isNil(mgr.maps[61].autonomousActions[actorId], "a nonresident actor must not start an autonomous action")
  Assert.isFalse(actor.resident)
  Assert.isNil(actor.surfaceId)
  Assert.equal(#mgr:drawRecords(), 0, "a nonresident actor must remain outside the physical projection")
  local captured = mgr:captureObjects()
  local validated, validationErr = FieldObjectSave.validate(captured)
  Assert.notNil(validated, tostring(validationErr))
  Assert.isNil(captured.actors[actorId].cellKey)
  mgr.autonomy.rng:nextInt(100)

  mgr:leaveMap(map.mapId)
  mgr:enterMap(map, eventState)
  actor = assert(mgr:getById(actorId))
  Assert.equal(actor.fieldX, 2)
  Assert.equal(actor.movementType, "stationary")
  Assert.equal(mgr.autonomy:captureRng().calls, 1)
  mgr:dispose()
end

function T.deferred_movement_type_capture_keeps_effective_profile_and_pending_type_distinct()
  local actorId = "map:61:object:0"
  local map = runtimeMap({ object({ movementType = "wander_north_south", xRange = -1, yRange = -1 }) })
  map.terrain:plate(0).cellKey = "0:0"
  map.terrain:plate(0).sourceSurfaceId = 0
  local mgr = manager(map.fieldData.events.objects, { map = map })
  local actor = assert(mgr:getById(actorId))
  mgr:step(1)
  Assert.isFalse(mgr:isPausable(actorId))

  mgr:setMovementType(actorId, "look_north")
  local record = mgr:captureObjects().actors[actorId]
  Assert.equal(record.movementType, "wander_north_south")
  Assert.equal(record.controller.kind, "wander")
  Assert.equal(record.controller.pendingMovementType, "look_north")
  Assert.equal(actor.movementType, "wander_north_south")
  mgr:dispose()
end

function T.preempting_autonomy_applies_deferred_movement_type_before_scripted_action()
  local actorId = "map:61:object:0"
  local mgr = manager({ object({ movementType = "wander_north_south", xRange = -1, yRange = -1 }) })
  for tick = 1, 32 do
    mgr:step(tick)
    if not mgr:isPausable(actorId) then
      break
    end
  end
  Assert.isFalse(mgr:isPausable(actorId))

  mgr:setMovementType(actorId, "look_north")
  mgr:beginScriptedAction(actorId, { action = "walk", direction = "east", speed = "normal" })
  mgr:advanceScriptedAction(actorId, 8, 8)
  mgr:commitScriptedAction(actorId)

  local captured = mgr:captureObjects()
  local validated, validationErr = FieldObjectSave.validate(captured)
  Assert.notNil(validated, tostring(validationErr))
  local record = captured.actors[actorId]
  Assert.equal(record.movementType, "look_north")
  Assert.isNil(record.controller.pendingMovementType)
  Assert.equal(assert(mgr:getById(actorId)).movementType, "look_north")
  mgr:dispose()
end

function T.failed_autonomy_attachment_rolls_back_actor_indexes_and_occupancy()
  local assets = fakeAssets({ [99] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  local map = runtimeMap({ object({ movementType = "not_a_movement_type" }) })
  Assert.throws(function()
    mgr:enterMap(map, FieldEventState.new())
  end)
  Assert.equal(#mgr:actorsOf(map.mapId), 0)
  Assert.equal(mgr:visualRevision(), 0)
  Assert.equal(assets:total(), 0)
  mgr:dispose()
end
function T.fixed_facing_movement_type_is_applied_on_the_field_tick()
  local mgr = manager({ object({ movementType = "look_north", facingDirection = "south" }) })
  local actor = assert(mgr:getById("map:61:object:0"))

  mgr:step(1)

  Assert.equal(actor.facing, "north")
  Assert.equal(actor.fieldX, 2)
  Assert.equal(actor.fieldZ, 3)
  mgr:dispose()
end

-- Logical actors survive outside the resident physical window, then reconcile
-- into draw/occupancy when the same logical zone admits their cell.
function T.logical_actors_survive_and_reconcile_physical_residency()
  local map = runtimeMap({
    object({ objectEventId = 0, x = 2, z = 3 }),
    object({ objectEventId = 1, x = 34, z = 3 }),
  })
  map.collision.containsLocal = function(_, fieldX, fieldZ)
    return fieldX >= 0 and fieldX < 64 and fieldZ >= 0 and fieldZ < 32
  end
  map.terrain = TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 64,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
  local nearResident = true
  local farResident = false
  map.coverage = {
    containsGlobal = function(_, fieldX, fieldZ)
      if fieldZ < 0 or fieldZ >= 32 then
        return false
      end
      return (fieldX < 32 and nearResident) or (fieldX >= 32 and farResident)
    end,
  }
  local mgr = manager(map.fieldData.events.objects, { map = map })
  local initialRevision = mgr:visualRevision()
  local nearId = "map:61:object:0"
  local farId = "map:61:object:1"
  local nearActor = assert(mgr:getById(nearId))
  local farActor = assert(mgr:getById(farId), "logical actors must not be culled by 3x3 residency")
  nearActor:setFacing("west")
  Assert.notNil(getAt(mgr, 61, 2, 3, nearActor.surfaceId))
  Assert.isNil(getAt(mgr, 61, 34, 3, 0))
  Assert.equal(#mgr:drawRecords(), 1, "only resident actors enter the draw projection")

  nearResident = false
  farResident = true
  mgr:reconcilePhysicalWorld()

  Assert.equal(mgr:getById(nearId), nearActor, "departing residency must preserve actor identity")
  Assert.equal(mgr:getById(farId), farActor, "entering residency must preserve actor identity")
  Assert.equal(nearActor.facing, "west", "departing residency must preserve mutable actor state")
  Assert.isNil(getAt(mgr, 61, 2, 3, nearActor.surfaceId))
  Assert.equal(getAt(mgr, 61, 34, 3, farActor.surfaceId), farActor)
  Assert.equal(#mgr:drawRecords(), 1, "only the newly resident actor enters the draw projection")
  Assert.equal(mgr:visualRevision(), initialRevision)
  mgr:dispose()
end

function T.physical_projection_keeps_centered_world_coordinates()
  local mgr = manager({ object({ x = 2, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  local before = {
    worldX = actor.worldX,
    worldY = actor.worldY,
    worldZ = actor.worldZ,
  }

  mgr:reconcilePhysicalWorld()

  Assert.equal(actor.worldX, before.worldX)
  Assert.equal(actor.worldY, before.worldY)
  Assert.equal(actor.worldZ, before.worldZ)
  Assert.equal(actor.worldX, -13.5)
  Assert.equal(actor.worldY, 0)
  Assert.equal(actor.worldZ, -12.5)
  Assert.equal(assert(getAt(mgr, 61, 2, 3, actor.surfaceId)), actor)
  local record = mgr:drawRecords()[1]
  Assert.equal(record.world.x, -13.5)
  Assert.equal(record.world.y, 0)
  Assert.equal(record.world.z, -12.5)
  mgr:dispose()
end

function T.actor_resolves_position_surface_and_world_anchor()
  local mgr = manager({ object({ x = 9, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.equal(actor.fieldX, 9)
  Assert.equal(actor.fieldZ, 3)
  -- Both plates cover x=9; the raw event Y hint selects the lower one.
  Assert.equal(actor.surfaceId, 0)
  Assert.equal(actor.worldY, 0)
end

function T.raw_event_y_hint_selects_the_stacked_surface()
  local mgr = manager({ object({ x = 9, z = 3, y = rawObjectEventY(4) }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.equal(actor.surfaceId, 1)
  Assert.equal(actor.worldY, 4)
  Assert.equal(actor.sourceEvent.y, rawObjectEventY(4))
  Assert.isTrue(actor.worldY ~= actor.sourceEvent.y)
  mgr:dispose()

  local halfHeightMap = runtimeMap({ object({ x = 9, z = 3, y = 32768 }) })
  halfHeightMap.terrain = TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 8,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
      {
        id = 1,
        minX = 8,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0.5,
        slopeClass = "flat",
      },
      {
        id = 2,
        minX = 8,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 4,
        slopeClass = "flat",
      },
    },
  })
  local halfHeightMgr = manager(halfHeightMap.fieldData.events.objects, { map = halfHeightMap })
  local halfHeightActor = assert(halfHeightMgr:getById("map:61:object:0"))
  Assert.equal(halfHeightActor.surfaceId, 1)
  Assert.equal(halfHeightActor.worldY, 0.5)
  halfHeightMgr:dispose()
end

function T.saved_actor_round_trip_uses_the_captured_source_surface()
  local objects = { object({ x = 9, z = 3 }) }
  local sourceMap = sourceRegionMap(objects, 0, terrain())
  local mgr = manager(objects, { map = sourceMap })
  local actor = assert(mgr:getById("map:61:object:0"))

  Assert.equal(actor.surfaceId, 0)
  Assert.equal(actor.cellKey, "0:0")
  Assert.equal(actor.sourceSurfaceId, 0)
  mgr:setPosition(actor.actorId, { fieldX = 9, fieldZ = 3, worldY = 4 })
  Assert.equal(actor.surfaceId, 1)
  Assert.equal(actor.sourceSurfaceId, 1)
  Assert.equal(actor.worldY, 4)

  local captured = mgr:captureObjects()
  local validated, validationErr = FieldObjectSave.validate(captured)
  Assert.notNil(validated, tostring(validationErr))
  local record = assert(validated).actors[actor.actorId]
  Assert.equal(record.cellKey, "0:0")
  Assert.equal(record.sourceSurfaceId, 1)
  mgr:dispose()

  local restoredObjects = { object({ x = 9, z = 3 }) }
  local restoredMap = sourceRegionMap(restoredObjects, 10, terrain())
  local restoredMgr = manager(restoredObjects, { map = restoredMap, restoredObjects = validated })
  local restored = assert(restoredMgr:getById(actor.actorId))

  Assert.equal(restored.cellKey, "0:0")
  Assert.equal(restored.sourceSurfaceId, 1)
  Assert.equal(restored.surfaceId, 11, "restore must reconstruct the current composite surface id")
  Assert.equal(restored.worldY, 4)
  Assert.equal(restored.sourceEvent.y, object({}).y)
  Assert.equal(restoredMgr:getAt(61, stableCandidate(9, 3, 11, "0:0", 1)), restored)
  Assert.isNil(restoredMgr:getAt(61, stableCandidate(9, 3, 10, "0:0", 0)))
  restoredMgr:dispose()
end

function T.missing_saved_source_surface_fails_before_y_fallback()
  local snapshot = capturedUpperSnapshot()
  local record = snapshot.actors["map:61:object:0"]
  record.fieldX = 21
  record.fieldZ = 3

  local objects = { object({ x = 9, z = 3 }) }
  local map = sourceRegionMap(
    objects,
    10,
    TerrainSurface.new({
      plates = {
        flatPlate(0, 0, 32, 0),
        flatPlate(2, 20, 24, 0),
      },
    })
  )
  local assets = fakeAssets({ [99] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })

  throwsCode("ACTOR_SURFACE_MISSING", function()
    mgr:enterMap(map, FieldEventState.new(), snapshot)
  end)
  Assert.isNil(mgr.maps[61], "a failed restore must not publish its entry")
  Assert.isNil(mgr.currentMapId, "a failed restore must not publish an active map")
  Assert.equal(#mgr:drawRecords(), 0, "a failed restore must not publish draw records")
  Assert.equal(assets:total(), 0, "a failed restore must release staged visuals")
  mgr:dispose()
end

function T.saved_source_surface_must_cover_the_saved_tile()
  local snapshot = capturedUpperSnapshot()
  local record = snapshot.actors["map:61:object:0"]
  record.fieldX = 35
  record.fieldZ = 3

  local objects = { object({ x = 9, z = 3 }) }
  local map = sourceRegionMap(
    objects,
    10,
    TerrainSurface.new({
      plates = {
        flatPlate(0, 0, 40, 0),
        flatPlate(1, 8, 20, 4),
        flatPlate(2, 32, 40, 0),
      },
    })
  )
  local assets = fakeAssets({ [99] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })

  throwsCode("ACTOR_SURFACE_MISSING", function()
    mgr:enterMap(map, FieldEventState.new(), snapshot)
  end)
  Assert.isNil(mgr.maps[61], "a non-covering restore must not publish its entry")
  Assert.equal(#mgr:drawRecords(), 0, "a non-covering restore must not publish draw records")
  Assert.equal(assets:total(), 0, "a non-covering restore must release staged visuals")
  mgr:dispose()
end

function T.identity_less_saved_actor_restore_keeps_the_source_y_selector()
  local objects = { object({ x = 9, z = 3, y = rawObjectEventY(4) }) }
  local map = runtimeMap(objects)
  local mgr = manager(objects, { map = map })
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.equal(actor.surfaceId, 1)
  Assert.equal(actor.worldY, 4)

  local captured = mgr:captureObjects()
  local validated, validationErr = FieldObjectSave.validate(captured)
  Assert.notNil(validated, tostring(validationErr))
  Assert.isNil(assert(validated).actors[actor.actorId].cellKey)
  mgr:dispose()

  local restoredMap = runtimeMap({ object({ x = 9, z = 3, y = rawObjectEventY(4) }) })
  local restoredMgr = manager(restoredMap.fieldData.events.objects, {
    map = restoredMap,
    restoredObjects = validated,
  })
  local restored = assert(restoredMgr:getById(actor.actorId))
  Assert.isNil(restored.cellKey)
  Assert.isNil(restored.sourceSurfaceId)
  Assert.equal(restored.surfaceId, 1)
  Assert.equal(restored.worldY, 4)
  Assert.equal(restored.sourceEvent.y, rawObjectEventY(4))
  restoredMgr:dispose()
end

function T.reprojection_uses_the_raw_event_y_hint_when_the_surface_is_stale()
  local mgr = manager({ object({ x = 9, z = 3, y = rawObjectEventY(4) }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  actor.surfaceId = 99

  mgr:reconcilePhysicalWorld()

  Assert.equal(actor.surfaceId, 1)
  Assert.equal(actor.worldY, 4)
  mgr:dispose()
end

function T.actor_off_the_terrain_is_fatal()
  throwsCode("ACTOR_SURFACE_MISSING", function()
    manager({ object({ x = 35, z = 3 }) })
  end)
end

function T.incomplete_source_surface_identity_is_fatal()
  local map = runtimeMap({ object({}) })
  map.terrain:plate(0).sourceSurfaceId = 0
  local err = Assert.throws(function()
    manager(map.fieldData.events.objects, { map = map })
  end)
  Assert.isTrue(
    type(err) == "string" and string.find(err, "source surface identity is incomplete", 1, true) ~= nil,
    "incomplete source identity must not be synthesized"
  )
end

function T.equally_near_surfaces_are_ambiguous_rather_than_guessed()
  throwsCode("ACTOR_SURFACE_AMBIGUOUS", function()
    manager({ object({ x = 21, z = 3 }) })
  end)
end

function T.unexpected_surface_resolution_errors_propagate_unchanged()
  -- Out-of-coverage is not an actor-surface condition: the coordinate failure
  -- must reach the caller as itself, not as ACTOR_SURFACE_MISSING.
  throwsCode("FIELD_COORDINATES_OUT_OF_COVERAGE", function()
    manager({ object({ x = 50, z = 3 }) })
  end)
end

function T.duplicate_object_event_ids_are_rejected()
  throwsCode("ACTOR_DUPLICATE_ID", function()
    manager({ object({ objectEventId = 0 }), object({ objectEventId = 0, x = 4 }) })
  end)
end

function T.two_solid_actors_on_one_cell_conflict()
  throwsCode("ACTOR_OCCUPANCY_CONFLICT", function()
    manager({ object({ objectEventId = 0 }), object({ objectEventId = 1, spriteId = 34 }) })
  end)
end

function T.destroying_a_non_solid_actor_keeps_the_solid_occupant()
  local mgr, eventState, assets = manager({
    object({ objectEventId = 0, eventFlag = 401 }),
    object({ objectEventId = 1, eventFlag = 402, solid = false }),
  })
  -- The non-solid actor shares the cell but never occupies it.
  Assert.notNil(mgr:getById("map:61:object:1"))
  Assert.equal(assert(getAt(mgr, 61, 2, 3, 0)).actorId, "map:61:object:0")
  eventState:setFlag(402)
  mgr:step(1)
  Assert.isNil(mgr:getById("map:61:object:1"))
  Assert.equal(assert(getAt(mgr, 61, 2, 3, 0), "the solid occupant survived").actorId, "map:61:object:0")
  Assert.isTrue(isOccupied(mgr, 61, 2, 3, 0))
  Assert.equal(assets:total(), 1)
end

function T.stale_occupancy_cannot_be_removed_by_the_wrong_actor()
  local mgr, _, assets = manager({ object({ objectEventId = 0 }) })
  local entry = assert(mgr.maps[61])
  -- A second solid actor whose cell coordinates match the occupant's, but
  -- which never occupied the cell itself: destroying it must not clear the
  -- occupant's entry.
  local imposter = FieldObjectActor.new({
    mapId = 61,
    sourceEvent = object({ objectEventId = 5 }),
    spriteId = 99,
    fieldX = 2,
    fieldZ = 3,
    surfaceId = 0,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    visual = FieldActorFixture.visual(99),
    idlePresentation = FieldActorFixture.visual(99).idlePresentation,
  })
  ---@cast imposter FieldActorManager.Actor
  assets:acquire(99)
  entry.actors[imposter.actorId] = imposter
  entry.order[#entry.order + 1] = imposter
  mgr:_destroy(entry, imposter)
  Assert.equal(assert(getAt(mgr, 61, 2, 3, 0), "the occupant entry survived").actorId, "map:61:object:0")
end

function T.uncompiled_sprite_is_fatal()
  throwsCode("ACTOR_VISUAL_MISSING", function()
    manager({ object({ spriteId = 148 }) })
  end)
end

function T.failed_actor_construction_releases_the_acquired_visual()
  -- The facing is validated inside FieldObjectActor.new, after the visual was
  -- acquired: the failed construction must return the visual to the provider.
  local assets = fakeAssets({ [99] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  throwsCode("ACTOR_FACING_INVALID", function()
    mgr:enterMap(runtimeMap({ object({ facingDirection = "northwest" }) }), FieldEventState.new())
  end)
  Assert.equal(assets:total(), 0)
end

function T.variable_sprite_resolves_to_the_hero_graphic_by_default()
  local mgr, _, assets = manager({ object({ spriteId = 101 }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.equal(actor.spriteId, 0)
  Assert.equal(assets.references[0], 1)
end

function T.variable_sprite_resolves_through_the_event_state_var()
  local eventState = FieldEventState.new({ vars = { [0x4020] = 34 } })
  local mgr, _, assets = manager({ object({ spriteId = 101 }) }, { eventState = eventState })
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.equal(actor.spriteId, 34)
  Assert.equal(actor.sourceEvent.spriteId, 101)
  Assert.equal(assets.references[34], 1)
end

function T.variable_sprite_re_resolves_at_each_object_creation()
  local eventState = FieldEventState.new({ flags = { [401] = true } })
  local mgr, _, assets = manager({ object({ spriteId = 101, eventFlag = 401 }) }, { eventState = eventState })
  Assert.isNil(mgr:getById("map:61:object:0"))
  eventState:setVar(0x4020, 34)
  eventState:clearFlag(401)
  mgr:step(1)
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.notNil(actor)
  Assert.equal(actor.spriteId, 34)
  Assert.equal(assets.references[34], 1)
end

function T.visual_sprite_requirements_are_distinct_and_revisioned()
  local mgr, eventState = manager({
    object({ objectEventId = 0, eventFlag = 401 }),
    object({ objectEventId = 1, spriteId = 99, x = 4 }),
    object({ objectEventId = 2, spriteId = 34, x = 6 }),
  })
  local initialRevision = mgr:visualRevision()
  local spriteIds = {}
  mgr:collectSpriteIds(spriteIds)
  Assert.isTrue(spriteIds[99])
  Assert.isTrue(spriteIds[34])

  mgr:step(1)
  Assert.equal(mgr:visualRevision(), initialRevision, "pose changes do not change visual requirements")

  eventState:setFlag(401)
  mgr:step(2)
  Assert.equal(mgr:visualRevision(), initialRevision + 1, "destroying an actor changes visual requirements")
  spriteIds = {}
  mgr:collectSpriteIds(spriteIds)
  Assert.isTrue(spriteIds[99], "a shared sprite remains required")
  Assert.isTrue(spriteIds[34])
end

function T.published_flag_actor_creation_and_destruction_invalidate_revision()
  local eventState = FieldEventState.new({ flags = { [401] = true } })
  local mgr = manager({ object({ eventFlag = 401 }) }, { eventState = eventState })
  local initialRevision = mgr:visualRevision()

  eventState:clearFlag(401)
  mgr:step(1)
  Assert.equal(mgr:visualRevision(), initialRevision + 1)

  eventState:setFlag(401)
  mgr:step(2)
  Assert.equal(mgr:visualRevision(), initialRevision + 2)
  mgr:dispose()
end

function T.occupancy_is_keyed_by_map_cell_and_surface()
  local mgr = manager({ object({ x = 9, z = 3 }) })
  Assert.isTrue(isOccupied(mgr, 61, 9, 3, 0))
  Assert.isFalse(isOccupied(mgr, 61, 9, 3, 1))
  Assert.isFalse(isOccupied(mgr, 61, 8, 3, 0))
  Assert.isFalse(isOccupied(mgr, 60, 9, 3, 0))
  Assert.isFalse(isOccupied(mgr, 61, 9, 3, 0, "map:61:object:0"))
  Assert.equal(assert(getAt(mgr, 61, 9, 3, 0)).actorId, "map:61:object:0")
end

function T.recentered_surface_ids_do_not_change_actor_occupancy()
  local map = runtimeMap({ object({ x = 2, z = 3 }) })
  map.terrain = TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
        cellKey = "0:0",
        sourceSurfaceId = 12,
      },
      {
        id = 7,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 1,
        slopeClass = "flat",
        cellKey = "0:0",
        sourceSurfaceId = 12,
      },
    },
  })
  local projectedSurfaceId = 0
  map.fieldRegion = {
    sourceSurface = function(_, cellKey, sourceSurfaceId)
      if cellKey == "0:0" and sourceSurfaceId == 12 then
        return projectedSurfaceId
      end
      return nil
    end,
  }

  local mgr = manager(map.fieldData.events.objects, { map = map })
  local actor = assert(mgr:getById("map:61:object:0"))
  projectedSurfaceId = 7
  mgr:reconcilePhysicalWorld()

  local currentCandidate = {
    fieldX = 2,
    fieldZ = 3,
    surfaceId = 7,
    cellKey = "0:0",
    sourceSurfaceId = 12,
  }
  local oldCandidate = {
    fieldX = 2,
    fieldZ = 3,
    surfaceId = 0,
    cellKey = "0:0",
    sourceSurfaceId = 12,
  }
  Assert.equal(mgr:getAt(61, currentCandidate), actor, "current composite IDs must not replace source identity")
  Assert.equal(mgr:getAt(61, oldCandidate), actor, "old composite IDs must not change source occupancy")
  mgr:dispose()
end

function T.stacked_source_surfaces_keep_same_coordinates_distinct()
  local map = runtimeMap({
    object({ objectEventId = 0, x = 9, z = 3, y = 0 }),
    object({ objectEventId = 1, x = 9, z = 3, y = rawObjectEventY(4), spriteId = 34 }),
  })
  map.terrain = TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
        cellKey = "0:0",
        sourceSurfaceId = 20,
      },
      {
        id = 1,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 4,
        slopeClass = "flat",
        cellKey = "0:0",
        sourceSurfaceId = 21,
      },
    },
  })

  local sameSourceMap = runtimeMap({
    object({ objectEventId = 0, x = 9, z = 3, y = 0 }),
    object({ objectEventId = 1, x = 9, z = 3, y = rawObjectEventY(4), spriteId = 34 }),
  })
  sameSourceMap.terrain = TerrainSurface.new({
    plates = {
      map.terrain:plate(0),
      {
        id = 1,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 4,
        slopeClass = "flat",
        cellKey = "0:0",
        sourceSurfaceId = 20,
      },
    },
  })
  throwsCode("ACTOR_OCCUPANCY_CONFLICT", function()
    manager(sameSourceMap.fieldData.events.objects, { map = sameSourceMap })
  end)

  local mgr = manager(map.fieldData.events.objects, { map = map })
  local lower = assert(mgr:getById("map:61:object:0"))
  local upper = assert(mgr:getById("map:61:object:1"))
  local lowerCandidate = {
    fieldX = 9,
    fieldZ = 3,
    surfaceId = 1,
    cellKey = "0:0",
    sourceSurfaceId = 20,
  }
  local upperCandidate = {
    fieldX = 9,
    fieldZ = 3,
    surfaceId = 0,
    cellKey = "0:0",
    sourceSurfaceId = 21,
  }

  Assert.equal(mgr:getAt(61, lowerCandidate), lower)
  Assert.equal(mgr:getAt(61, upperCandidate), upper)
  mgr:dispose()
end

function T.preflight_probe_uses_event_rules_without_publishing_actors()
  local eventState = FieldEventState.new({ flags = { [401] = true } })
  local mgr, _, assets, source = manager({}, { eventState = eventState })
  local destination = runtimeMap({
    object({ objectEventId = 0, eventFlag = 401 }),
    object({ objectEventId = 1, solid = false }),
    object({ objectEventId = 2, x = 9, y = rawObjectEventY(4) }),
  }, 62)
  local revision = mgr:visualRevision()

  Assert.isNil(mgr:probeAt(destination, eventState, candidate(2, 3, 0)), "flagged and non-solid events do not occupy")
  Assert.isNil(mgr:probeAt(destination, eventState, candidate(9, 3, 0)), "a different surface does not occupy")
  local occupant = assert(mgr:probeAt(destination, eventState, candidate(9, 3, 1)))
  Assert.equal(occupant.objectEventId, 2)
  Assert.isNil(mgr.maps[62], "preflight must not publish a destination map")
  Assert.equal(mgr.currentMapId, source.mapId)
  Assert.equal(assets:total(), 0, "preflight must not acquire visuals")
  Assert.equal(mgr:visualRevision(), revision)
  mgr:dispose()
end

-- Both collision and interaction callers need semantic identity from a
-- probe, not just the numeric ids: the source event (for its scriptId) and
-- the resolved sprite id (using the same variable-sprite policy activation
-- uses), without ever acquiring a visual definition.
function T.probe_result_carries_source_event_and_resolved_sprite_identity()
  local eventState = FieldEventState.new()
  local mgr, _, assets = manager({}, { eventState = eventState })
  local destinationEvent = object({ objectEventId = 7, x = 9, z = 3, spriteId = 101 })
  local destination = runtimeMap({ destinationEvent }, 62)
  eventState:setVar(0x4020, 34)
  local revision = mgr:visualRevision()

  local occupant = assert(mgr:probeAt(destination, eventState, candidate(9, 3, 0)))
  Assert.equal(occupant.objectEventId, 7)
  Assert.equal(occupant.sourceEvent, destinationEvent, "the probe result must expose the source event")
  Assert.equal(occupant.spriteId, 34, "the probe result must resolve a variable sprite from the supplied event state")
  Assert.isNil(mgr.maps[62], "probing must not publish a destination map")
  Assert.equal(assets:total(), 0, "probing must not acquire a visual definition")
  Assert.equal(mgr:visualRevision(), revision)
  mgr:dispose()
end

function T.preflight_probe_rejects_two_solid_events_on_one_surface()
  local mgr, _, _, source = manager({})
  local destination = runtimeMap({
    object({ objectEventId = 0 }),
    object({ objectEventId = 1, spriteId = 34 }),
  }, 62)
  throwsCode("ACTOR_OCCUPANCY_CONFLICT", function()
    mgr:probeAt(destination, FieldEventState.new(), candidate(2, 3, 0))
  end)
  Assert.equal(mgr.currentMapId, source.mapId)
  Assert.isNil(mgr.maps[62])
  mgr:dispose()
end

function T.setting_a_flag_removes_draw_and_occupancy_on_one_tick()
  local mgr, eventState, assets = manager({ object({ eventFlag = 401 }) })
  Assert.equal(assets:total(), 1)
  eventState:setFlag(401)
  -- Nothing changes until the manager's fixed-tick boundary.
  Assert.notNil(mgr:getById("map:61:object:0"))
  mgr:step(1)
  Assert.isNil(mgr:getById("map:61:object:0"))
  Assert.equal(#mgr:drawRecords(), 0)
  Assert.isFalse(isOccupied(mgr, 61, 2, 3, 0))
  Assert.equal(assets:total(), 0)
end

function T.clearing_a_flag_restores_the_actor_at_its_source_state()
  local eventState = FieldEventState.new({ flags = { [401] = true } })
  local mgr, _, assets = manager({ object({ eventFlag = 401, facingDirection = "west" }) }, { eventState = eventState })
  Assert.isNil(mgr:getById("map:61:object:0"))
  eventState:clearFlag(401)
  mgr:step(1)
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.notNil(actor)
  Assert.equal(actor.facing, "west")
  Assert.isTrue(isOccupied(mgr, 61, 2, 3, 0))
  Assert.equal(assets:total(), 1)
end

function T.hiding_an_actor_drops_its_facing_override()
  local mgr, eventState = manager({ object({ eventFlag = 401 }) })
  mgr:getById("map:61:object:0"):pushFacingOverride({ owner = "test", facing = "north" })
  eventState:setFlag(401)
  mgr:step(1)
  eventState:clearFlag(401)
  mgr:step(2)
  Assert.equal(mgr:getById("map:61:object:0").facing, "south")
end

function T.entering_the_same_map_twice_is_idempotent()
  local mgr, eventState, assets, map = manager({ object({}) })
  local initialRevision = mgr:visualRevision()
  mgr:enterMap(map, eventState)
  Assert.equal(#mgr:drawRecords(), 1)
  Assert.equal(assets:total(), 1)
  Assert.equal(mgr:visualRevision(), initialRevision)
end

function T.publishing_an_empty_map_does_not_change_revision()
  local assets = fakeAssets({ [99] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  local eventState = FieldEventState.new()
  Assert.equal(mgr:visualRevision(), 0)

  mgr:enterMap(runtimeMap({}, 61), eventState)

  Assert.equal(mgr:visualRevision(), 0)
  mgr:dispose()
end

-- enterMap is the sole production activation seam: it must stage the
-- destination entry completely, and bind its event state, while the
-- previous active entry remains untouched, retiring the previous entry only
-- after the destination publication succeeds.
function T.enter_map_replacement_preserves_the_previous_entry_until_destination_construction_succeeds()
  local mgr, eventState, assets = manager({ object({}) })
  local failingReplacement = runtimeMap({ object({ facingDirection = "northwest" }) }, 61)

  throwsCode("ACTOR_FACING_INVALID", function()
    mgr:enterMap(failingReplacement, eventState)
  end)

  Assert.notNil(
    mgr:getById("map:61:object:0"),
    "a failed destination construction must not destroy the previous active entry"
  )
  Assert.equal(mgr.currentMapId, 61)
  Assert.equal(assets:total(), 1, "only the previous entry's visual remains referenced")
  mgr:dispose()
end

function T.enter_map_replacement_preserves_the_previous_entry_on_a_bind_failure()
  local mgr, _, assets = manager({ object({}) })
  local replacement = runtimeMap({ object({ objectEventId = 5, spriteId = 34 }) }, 61)
  local failingState = {
    isFlagSet = function()
      return false
    end,
    subscribe = function()
      error("event subscription failed", 0)
    end,
  }
  ---@cast failingState FieldEventState

  local ok, err = pcall(function()
    mgr:enterMap(replacement, failingState)
  end)
  Assert.isFalse(ok)
  Assert.equal(err, "event subscription failed")
  Assert.notNil(mgr:getById("map:61:object:0"), "a bind failure must not destroy the previous active entry")
  Assert.equal(mgr.currentMapId, 61)
  Assert.equal(assets:total(), 1, "the failed replacement's staged visual must not remain referenced")
  mgr:dispose()
end

function T.enter_map_replaces_the_same_map_id_without_losing_the_new_entry()
  local mgr, eventState, assets, source = manager({ object({}) })
  local replacement = runtimeMap({ object({ objectEventId = 5, spriteId = 34 }) }, source.mapId)

  mgr:enterMap(replacement, eventState)

  Assert.notNil(mgr:getById("map:61:object:5"), "the replacement entry must be published")
  Assert.isNil(mgr:getById("map:61:object:0"), "the previous entry is retired only after the replacement publishes")
  Assert.equal(mgr.maps[source.mapId].runtimeMap, replacement)
  Assert.equal(mgr.currentMapId, source.mapId)
  Assert.equal(assets:total(), 1)
  mgr:dispose()
end

-- A runtime map without the compiled object collection is a malformed
-- record, never an empty map: enterMap fails and rolls the entry back, the
-- same shape as a mid-construction actor failure.
function T.enter_map_without_object_collection_fails_and_rolls_back()
  local mgr = FieldActorManager.new({ assets = fakeAssets({ [99] = true }), policy = POLICY })
  local err = Assert.throws(function()
    mgr:enterMap(runtimeMap(nil), FieldEventState.new())
  end)
  Assert.isTrue(
    tostring(err):find("compiled object collection", 1, true) ~= nil,
    "the failure names the missing collection"
  )
  Assert.isNil(mgr.maps[61], "no partial map entry remains")
  Assert.equal(#mgr:drawRecords(), 0)
  mgr:dispose()
end

function T.leaving_a_map_releases_every_visual()
  local mgr, _, assets = manager({ object({}), object({ objectEventId = 1, spriteId = 34, x = 4 }) })
  local initialRevision = mgr:visualRevision()
  mgr:leaveMap(61)
  Assert.equal(assets:total(), 0)
  Assert.isNil(mgr:getById("map:61:object:0"))
  Assert.isFalse(isOccupied(mgr, 61, 2, 3, 0))
  Assert.equal(mgr:visualRevision(), initialRevision + 1)
end

function T.repeated_map_round_trips_do_not_leak_actors_or_visuals()
  local mgr, eventState, assets, map = manager({ object({}) })
  for _ = 1, 3 do
    mgr:leaveMap(61)
    mgr:enterMap(map, eventState)
  end
  Assert.equal(#mgr:drawRecords(), 1)
  Assert.equal(assets:total(), 1)
  mgr:dispose()
  Assert.equal(assets:total(), 0)
end

-- One live actor world at a time: entering a destination retires the source
-- entry and releases its visuals once the destination is published.
function T.entering_a_destination_retires_the_previous_active_entry()
  local assets = fakeAssets({ [99] = true, [34] = true })
  local eventState = FieldEventState.new()
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  mgr:enterMap(runtimeMap({ object({}) }, 61), eventState)
  mgr:enterMap(runtimeMap({ object({ spriteId = 34 }) }, 60), eventState)

  Assert.isFalse(isOccupied(mgr, 61, 2, 3, 0), "the source entry is retired by the destination activation")
  Assert.isNil(mgr.maps[61])
  Assert.isTrue(isOccupied(mgr, 60, 2, 3, 0))
  Assert.equal(mgr.currentMapId, 60)
  Assert.equal(assets:total(), 1, "only the active entry's visual remains referenced")
  mgr:dispose()
end

-- A real FieldPlayer whose occupancy predicate reads this manager's index,
-- integrating the terrain resolver and the move.
local function playerOn(mgr, map, fieldX, fieldZ, surfaceId)
  map.collision.isBlockedLocal = function()
    return false
  end
  local p = FieldPlayer.new({
    currentMap = map,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    facing = "south",
    occupancy = function(moveCandidate)
      local occupant = mgr:getAt(map.mapId, moveCandidate)
      return occupant and occupant.actorId or nil
    end,
  })
  return p
end

-- Script integration: the actor world resolves numeric map-object indexes
-- through the manager's current map, and scripted show/hide reach the draw
-- records.
function T.script_actor_world_resolves_map_indexes_and_visibility()
  local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
  local mgr = manager({
    object({ objectEventId = 2, x = 4, z = 5 }),
    object({ objectEventId = 241, x = 7, z = 8 }),
    object({ objectEventId = 253, x = 9, z = 9 }),
  })
  local player = {
    position = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
    gender = function()
      return 0
    end,
    name = function()
      return "Gold"
    end,
  }
  local world = ScriptActorWorld.new(mgr --[[@as ScriptActorManager]], player)
  Assert.equal(world:actorIdForMapIndex(2), "map:61:object:2")
  Assert.isNil(world:actorIdForMapIndex(99))
  Assert.equal(world:cameraTargetId(), "map:61:object:241")
  Assert.equal(world:partnerId(), "map:61:object:253")
  world:hide("map:61:object:2")
  local records = mgr:drawRecords()
  for _, record in ipairs(records) do
    if record.actorId == "map:61:object:2" then
      Assert.isFalse(record.visible, "hide_object reaches the draw records")
    else
      Assert.isTrue(record.visible)
    end
  end
  world:show("map:61:object:2")
  for _, record in ipairs(mgr:drawRecords()) do
    if record.actorId == "map:61:object:2" then
      Assert.isTrue(record.visible, "show_object restores draw visibility")
    end
  end
end

-- Scripted set_position onto another solid actor's cell is a conflict, never
-- a silent occupancy overwrite, for every caller that does not identify
-- itself as script-driven (autonomous walk-AI/player-vs-object movement, and
-- the default when no options are given).
function T.script_set_position_cannot_overwrite_occupancy()
  local mgr = manager({
    object({ objectEventId = 0, x = 2, z = 3 }),
    object({ objectEventId = 1, x = 8, z = 3 }),
  })
  local _ = mgr:getById("map:61:object:1")
  throwsCode("ACTOR_OCCUPANCY_CONFLICT", function()
    mgr:setPosition("map:61:object:0", { fieldX = 8, fieldZ = 3 })
  end)
  Assert.equal(assert(getAt(mgr, 61, 8, 3, 0), "the occupant entry survived the conflict").actorId, "map:61:object:1")
  Assert.equal(assert(getAt(mgr, 61, 2, 3, 0), "the mover kept its old cell").actorId, "map:61:object:0")
end

-- Pinned HGSS source performs no inter-object collision check while a
-- script's ApplyMovement repositions an actor, so a script-driven setPosition
-- (options.scripted) may land on another solid actor's cell without raising;
-- the mover simply takes over the occupancy slot.
function T.scripted_set_position_may_overwrite_occupancy()
  local mgr = manager({
    object({ objectEventId = 0, x = 2, z = 3 }),
    object({ objectEventId = 1, x = 8, z = 3 }),
  })
  mgr:setPosition("map:61:object:0", { fieldX = 8, fieldZ = 3 }, { scripted = true })
  Assert.equal(assert(getAt(mgr, 61, 8, 3, 0), "the mover now occupies the shared cell").actorId, "map:61:object:0")
  Assert.isNil(getAt(mgr, 61, 2, 3, 0), "the mover's old cell is vacated")
end

-- A coordinate-conversion failure must leave the actor in its old cell with
-- its old position: the whole destination (coordinates, surface, occupancy)
-- is validated before any mutation.
function T.script_set_position_conversion_failure_keeps_occupancy()
  local mgr = manager({ object({ objectEventId = 0, x = 2, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  throwsCode("FIELD_COORDINATES_OUT_OF_COVERAGE", function()
    mgr:setPosition("map:61:object:0", { fieldX = 100, fieldZ = 3 })
  end)
  Assert.equal(actor.fieldX, 2, "the actor keeps its old position")
  Assert.equal(assert(getAt(mgr, 61, 2, 3, 0), "the mover kept its old cell").actorId, "map:61:object:0")
end

-- A destination inside the permission coverage but without terrain (or with
-- an unresolvable surface) is equally transactional.
function T.script_set_position_surface_failure_keeps_occupancy()
  local mgr = manager({ object({ objectEventId = 0, x = 2, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  throwsCode("TERRAIN_SURFACE_NOT_FOUND", function()
    mgr:setPosition("map:61:object:0", { fieldX = 35, fieldZ = 3 })
  end)
  Assert.equal(actor.fieldX, 2, "the actor keeps its old position")
  Assert.equal(assert(getAt(mgr, 61, 2, 3, 0), "the mover kept its old cell").actorId, "map:61:object:0")
end

-- A move onto a different terrain plate updates the surface used by occupancy
-- and interaction: an explicit worldY selects the stacked plate, and the
-- occupancy index rekeys on that surface.
function T.script_set_position_across_surfaces_rekeys_occupancy()
  local mgr = manager({ object({ objectEventId = 0, x = 2, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.equal(actor.surfaceId, 0)
  mgr:setPosition("map:61:object:0", { fieldX = 9, fieldZ = 3, worldY = 4 })
  Assert.equal(actor.surfaceId, 1, "the destination surface follows the resolved plate")
  Assert.equal(actor.worldY, 4)
  Assert.equal(assert(getAt(mgr, 61, 9, 3, 1), "occupancy rekeys on the new surface").actorId, "map:61:object:0")
  Assert.isNil(getAt(mgr, 61, 9, 3, 0), "no occupancy on the old surface at the destination")
  Assert.isNil(getAt(mgr, 61, 2, 3, 0), "the old cell is vacated")
end

-- Without an explicit worldY the actor stays on its current surface when it
-- covers the destination: scripted movement keeps the actor on its plate.
function T.script_set_position_without_world_y_stays_on_the_current_surface()
  local mgr = manager({ object({ objectEventId = 0, x = 2, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  mgr:setPosition("map:61:object:0", { fieldX = 9, fieldZ = 3 })
  Assert.equal(actor.surfaceId, 0, "the current surface covers the destination and is preserved")
  Assert.equal(actor.worldY, 0)
  Assert.equal(assert(getAt(mgr, 61, 9, 3, 0)).actorId, "map:61:object:0")
end

function T.script_set_position_preserves_logical_identity_until_destination_resides()
  local map = runtimeMap({ object({ objectEventId = 0, x = 2, z = 3 }) })
  map.terrain = TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 64,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
        cellKey = "0:0",
        sourceSurfaceId = 0,
      },
    },
  })
  local resident = false
  map.coverage = {
    containsGlobal = function(_, fieldX)
      return fieldX < 32 or resident
    end,
  }
  map.fieldRegion = {
    sourceSurface = function(_, cellKey, sourceSurfaceId)
      if (cellKey == "0:0" or cellKey == "1:0") and sourceSurfaceId == 0 then
        return 0
      end
      return nil
    end,
  }
  local mgr = manager(map.fieldData.events.objects, { map = map })
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.equal(actor.cellKey, "0:0")
  Assert.equal(actor.sourceSurfaceId, 0)

  local candidatesAt = map.terrain.candidatesAt
  map.terrain.candidatesAt = function()
    error("nonresident actor movement must not resolve terrain")
  end
  mgr:setPosition(actor.actorId, { fieldX = 34, fieldZ = 3 })
  map.terrain.candidatesAt = candidatesAt

  Assert.equal(actor.fieldX, 34)
  Assert.equal(actor.fieldZ, 3)
  Assert.equal(actor.cellKey, "1:0", "scripted movement updates the logical cell identity")
  Assert.isNil(actor.sourceSurfaceId, "a nonresident actor must not retain an old cell's surface slot")
  Assert.isFalse(actor.resident)
  Assert.isNil(mgr:getAt(61, stableCandidate(34, 3, 0, "1:0", 0)), "a nonresident actor never enters guessed occupancy")
  Assert.equal(#mgr:drawRecords(), 0, "a nonresident actor is absent from the physical draw projection")

  resident = true
  mgr:reconcilePhysicalWorld()

  Assert.isTrue(actor.resident)
  Assert.equal(actor.cellKey, "1:0")
  Assert.equal(actor.sourceSurfaceId, 0)
  Assert.equal(assert(mgr:getAt(61, stableCandidate(34, 3, 0, "1:0", 0))), actor)
  Assert.equal(#mgr:drawRecords(), 1)
  mgr:dispose()
end

-- Hidden actors stay solid for collision and report hidden snapshots: the
-- two views never contradict.
function T.hidden_actors_report_hidden_snapshots_and_stay_solid()
  local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
  local mgr = manager({ object({ objectEventId = 0, x = 2, z = 3 }) })
  local player = {
    position = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
    gender = function()
      return 0
    end,
    name = function()
      return "Gold"
    end,
  }
  local world = ScriptActorWorld.new(mgr --[[@as ScriptActorManager]], player)
  mgr:hide("map:61:object:0")
  Assert.isFalse(mgr:getById("map:61:object:0").visible)
  Assert.isTrue(isOccupied(mgr, 61, 2, 3, 0), "hidden actors remain solid for collision")
  Assert.equal(world:snapshot("map:61:object:0").visible, false, "hide_object reflects in snapshots")
  world:show("map:61:object:0")
  Assert.equal(world:snapshot("map:61:object:0").visible, true, "show_object restores snapshot visibility")
end

function T.scripted_reposition_autonomous_reservation_and_destroy_keep_stable_cells_transactional()
  local map = runtimeMap({
    object({ objectEventId = 0, eventFlag = 401, movementType = "wander_around", x = 31, xRange = 2, yRange = -1 }),
  })
  map.terrain = TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
        cellKey = "0:0",
        sourceSurfaceId = 12,
      },
      {
        id = 1,
        minX = 32,
        minZ = 0,
        maxX = 64,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
        cellKey = "1:0",
        sourceSurfaceId = 13,
      },
    },
  })
  map.fieldRegion = {
    sourceSurface = function(_, cellKey, sourceSurfaceId)
      if cellKey == "0:0" and sourceSurfaceId == 12 then
        return 0
      elseif cellKey == "1:0" and sourceSurfaceId == 13 then
        return 1
      end
      return nil
    end,
  }
  local eventState = FieldEventState.new()
  local mgr = manager(map.fieldData.events.objects, { eventState = eventState, map = map })
  local actorId = "map:61:object:0"
  local actor = assert(mgr:getById(actorId))

  Assert.equal(actor.fieldX, 31)
  Assert.equal(actor.cellKey, "0:0")
  Assert.equal(actor.sourceSurfaceId, 12)
  Assert.equal(assert(mgr:getAt(61, stableCandidate(31, 3, 0, "0:0", 12))), actor)

  mgr:beginScriptedAction(actorId, { action = "walk", direction = "east", speed = "normal" })
  mgr:advanceScriptedAction(actorId, 8, 8)
  mgr:commitScriptedAction(actorId)

  Assert.equal(actor.fieldX, 32)
  Assert.equal(actor.cellKey, "1:0", "scripted commit must publish the destination source cell")
  Assert.equal(actor.sourceSurfaceId, 13)
  Assert.isNil(mgr:getAt(61, stableCandidate(31, 3, 0, "0:0", 12)))
  Assert.equal(assert(mgr:getAt(61, stableCandidate(32, 3, 1, "1:0", 13))), actor)

  forceAutonomy(mgr, "east")
  mgr:step(1)
  local entry = assert(mgr.maps[61])
  local action = assert(entry.autonomousActions[actorId])
  Assert.equal(actor.fieldX, 32, "an autonomous step keeps the scripted committed cell until completion")
  Assert.equal(action.destination.fieldX, 33)
  Assert.notNil(entry.reservations[action.reservationKey], "the autonomous destination must be reserved")

  for tick = 2, 9 do
    mgr:step(tick)
  end

  Assert.equal(actor.fieldX, 33)
  Assert.equal(actor.cellKey, "1:0")
  Assert.equal(actor.sourceSurfaceId, 13)
  Assert.isNil(mgr:getAt(61, stableCandidate(32, 3, 1, "1:0", 13)))
  Assert.equal(assert(mgr:getAt(61, stableCandidate(33, 3, 1, "1:0", 13))), actor)

  eventState:setFlag(401)
  mgr:step(10)

  Assert.isNil(mgr:getById(actorId), "destroying an actor cancels its active autonomous action")
  Assert.isNil(entry.autonomousActions[actorId], "destroying an actor clears its autonomous action")
  Assert.isNil(entry.reservations[action.reservationKey], "destroying an actor clears its destination reservation")
  Assert.isNil(
    mgr:getAt(61, stableCandidate(31, 3, 0, "0:0", 12)),
    "destroying an actor leaves its scripted departure cell free"
  )
  Assert.isNil(
    mgr:getAt(61, stableCandidate(32, 3, 1, "1:0", 13)),
    "destroying an actor leaves its autonomous departure cell free"
  )
  Assert.isNil(mgr:getAt(61, stableCandidate(33, 3, 1, "1:0", 13)), "destroying an actor vacates its committed cell")
  Assert.throws(function()
    mgr.autonomy:state(actorId)
  end)
  mgr:dispose()
end

function T.autonomous_wander_settles_before_its_wait()
  local mgr = manager(
    { object({ movementType = "wander_around", xRange = -1, yRange = -1 }) },
    { autonomyRng = deterministicRng({ 3, 0 }) }
  )
  local actorId = "map:61:object:0"
  local actor = assert(mgr:getById(actorId))
  local entry = assert(mgr.maps[61])

  mgr:step(1)
  Assert.equal(actor.pose, "walk")
  Assert.notNil(entry.autonomousActions[actorId])
  for tick = 2, 8 do
    mgr:step(tick)
    Assert.equal(actor.pose, "walk", "a wandering actor walks while its autonomous action is active")
    Assert.notNil(entry.autonomousActions[actorId])
  end

  mgr:step(9)
  Assert.equal(actor.fieldX, 3)
  Assert.equal(actor.fieldZ, 3)
  Assert.isNil(entry.autonomousActions[actorId])
  Assert.equal(actor.pose, "idle", "a completed wandering step settles before its wait")
  Assert.equal(actor.poseTick, 0, "settling restores the idle pose-clock baseline")

  mgr:step(10)
  mgr:step(11)
  Assert.isNil(entry.autonomousActions[actorId])
  Assert.equal(actor.pose, "idle", "the actor remains idle throughout its controller wait")
  mgr:dispose()
end

function T.autonomous_pattern_continues_without_an_idle_boundary()
  local mgr = manager({
    object({
      movementType = "walk_north_east_west_south",
      facingDirection = "north",
      xRange = -1,
      yRange = -1,
    }),
  })
  local actorId = "map:61:object:0"
  local actor = assert(mgr:getById(actorId))
  local entry = assert(mgr.maps[61])

  mgr:step(1)
  for tick = 2, 8 do
    mgr:step(tick)
  end
  mgr:step(9)
  Assert.equal(actor.fieldX, 2)
  Assert.equal(actor.fieldZ, 2)
  Assert.equal(actor.pose, "idle", "a continuous step settles to the visual idle presentation at commit")
  Assert.isNil(entry.autonomousActions[actorId])

  mgr:step(10)
  Assert.equal(actor.pose, "walk", "a successful successor starts a new active presentation")
  local successor = assert(entry.autonomousActions[actorId])
  Assert.equal(successor.destination.fieldX, 3)
  Assert.equal(successor.destination.fieldZ, 2)
  mgr:dispose()
end

function T.autonomous_pattern_settles_when_continuation_is_blocked()
  local mgr = manager({
    object({
      objectEventId = 0,
      movementType = "walk_north_east_west_south",
      facingDirection = "north",
      xRange = -1,
      yRange = -1,
    }),
    object({ objectEventId = 1, x = 3, z = 2 }),
    object({ objectEventId = 2, x = 1, z = 2 }),
  })
  local actorId = "map:61:object:0"
  local actor = assert(mgr:getById(actorId))
  local entry = assert(mgr.maps[61])

  mgr:step(1)
  for tick = 2, 8 do
    mgr:step(tick)
  end
  mgr:step(9)
  Assert.equal(actor.fieldX, 2)
  Assert.equal(actor.fieldZ, 2)
  Assert.equal(actor.pose, "idle")
  Assert.isNil(entry.autonomousActions[actorId])

  mgr:step(10)
  Assert.equal(actor.fieldX, 2, "a blocked successor leaves the actor on its committed tile")
  Assert.equal(actor.fieldZ, 2, "a blocked successor leaves the actor on its committed tile")
  Assert.isNil(entry.autonomousActions[actorId])
  Assert.isNil(next(entry.reservations))
  Assert.equal(actor.pose, "idle", "a failed continuous successor settles the actor")
  Assert.equal(actor.poseTick, 0, "settling clears the static idle phase")
  mgr:dispose()
end

function T.destroying_a_carried_actor_clears_only_its_presentation_state()
  local eventState = FieldEventState.new()
  local mgr = manager({
    object({
      objectEventId = 0,
      eventFlag = 401,
      movementType = "walk_north_east_west_south",
      facingDirection = "north",
      xRange = -1,
      yRange = -1,
    }),
    object({ objectEventId = 1, x = 10, z = 3 }),
  }, { eventState = eventState })
  local carriedActorId = "map:61:object:0"
  local otherActorId = "map:61:object:1"
  local entry = assert(mgr.maps[61])
  local carriedActor = assert(mgr:getById(carriedActorId))
  local otherActor = assert(mgr:getById(otherActorId))

  mgr:step(1)
  for tick = 2, 9 do
    mgr:step(tick)
  end
  Assert.equal(carriedActor.pose, "idle")
  Assert.isNil(entry.autonomousActions[carriedActorId])
  Assert.isTrue(entry.autonomousPresentationCarry[carriedActorId])

  eventState:setFlag(401)
  mgr:step(10)

  Assert.isNil(mgr:getById(carriedActorId))
  Assert.isNil(entry.autonomousActions[carriedActorId])
  Assert.isNil(entry.autonomousPresentationCarry[carriedActorId])
  Assert.isNil(next(entry.reservations))
  Assert.equal(assert(mgr:getById(otherActorId)), otherActor)
  Assert.equal(otherActor.pose, "idle")
  mgr:dispose()
end

function T.player_cannot_step_into_a_visible_solid_actor_cell()
  local mgr, _, _, map = manager({ object({ objectEventId = 0, x = 9, z = 3 }) })
  local p = playerOn(mgr, map, 9, 2, 0)
  p:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(p.facing, "south")
  Assert.equal(p.fieldZ, 2)
  Assert.equal(p.motion, "idle")
end

function T.hiding_the_actor_opens_the_cell_for_the_player()
  local mgr, eventState, _, map = manager({ object({ objectEventId = 0, x = 9, z = 3, eventFlag = 401 }) })
  local p = playerOn(mgr, map, 9, 2, 0)
  eventState:setFlag(401)
  mgr:step(1)
  p:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(p.motion, "walking")
  for _ = 2, 8 do
    p:updateFixed({ heldDirection = "south" })
  end
  Assert.equal(p.fieldZ, 3)
  Assert.isFalse(isOccupied(mgr, 61, 9, 3, 0))
end

function T.an_actor_on_the_lower_surface_does_not_block_the_stacked_cell()
  -- The actor sits on plate 0 at (9,3); the player approaches on plate 1
  -- (four units higher), so the resolved destination surface is 1 and the
  -- step must succeed even though x/z match.
  local mgr, _, _, map = manager({ object({ objectEventId = 0, x = 9, z = 3 }) })
  local p = playerOn(mgr, map, 9, 2, 1)
  p:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(p.motion, "walking")
  for _ = 2, 8 do
    p:updateFixed({ heldDirection = "south" })
  end
  Assert.equal(p.fieldZ, 3)
  Assert.equal(p.surfaceId, 1)
  Assert.isTrue(isOccupied(mgr, 61, 9, 3, 0))
end

function T.idle_pose_clock_stays_stable_for_visible_actors()
  local mgr, eventState = manager({ object({ eventFlag = 401 }) })
  mgr:step(1)
  mgr:step(2)
  Assert.equal(mgr:getById("map:61:object:0").poseTick, 0)
  eventState:setFlag(401)
  mgr:step(3)
  eventState:clearFlag(401)
  -- A rematerialized actor starts a fresh stable idle presentation.
  mgr:step(4)
  Assert.equal(mgr:getById("map:61:object:0").poseTick, 0)
end

function T.autonomous_range_uses_signed_source_origin_bounds()
  local function attempts(overrides, direction, reposition)
    local mgr = manager({ object(overrides) })
    local actor = assert(mgr:getById("map:61:object:0"))
    if reposition then
      reposition(mgr)
    end
    local count = 0
    forceAutonomy(mgr, direction, function()
      count = count + 1
    end)
    mgr:step(1)
    local action = mgr.maps[61].autonomousActions[actor.actorId]
    mgr:dispose()
    return count, action ~= nil
  end

  local _, xZeroAccepted = attempts({ movementType = "wander_around", xRange = 0, yRange = -1 }, "east")
  Assert.isFalse(xZeroAccepted, "zero X range must keep the actor at its source X")

  local _, zZeroAccepted = attempts({ movementType = "wander_around", xRange = -1, yRange = 0 }, "south")
  Assert.isFalse(zZeroAccepted, "zero Z range must keep the actor at its source Z")

  local _, boundaryAccepted = attempts({ movementType = "wander_around", xRange = 1, yRange = -1 }, "east")
  Assert.isTrue(boundaryAccepted, "a positive range includes its exact source-origin boundary")

  local _, pastBoundaryAccepted = attempts(
    { movementType = "wander_around", xRange = 1, yRange = -1 },
    "east",
    function(mgr)
      mgr:setPosition("map:61:object:0", { fieldX = 3, fieldZ = 3 })
    end
  )
  Assert.isFalse(pastBoundaryAccepted, "a positive range rejects the tile past its boundary")

  Assert.throws(function()
    attempts({ movementType = "wander_around", xRange = -2, yRange = -1 }, "east")
  end)
  Assert.throws(function()
    attempts({ movementType = "wander_around", xRange = -1, yRange = -2 }, "south")
  end)
end

function T.autonomy_capability_uses_truncated_source_y_bands()
  local mgr = manager({ object({ movementType = "look_north" }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  actor.worldY = 1.25
  local player = { fieldX = 4, fieldZ = 4, worldY = -0.75, surfaceId = 999 }
  local observed
  forceAutonomy(mgr, "north", function(capability)
    observed = capability
  end)

  mgr:step(1, { player = player })

  Assert.equal(observed.positionYBand, 2, "positive normalized Y uses truncation toward zero")
  Assert.equal(observed.player.positionYBand, -1, "negative normalized Y uses truncation toward zero")
  Assert.isNil(player.positionYBand, "deriving the band must not mutate caller-owned player facts")
  mgr:dispose()
end

function T.draw_records_are_presentation_neutral()
  local mgr = manager({ object({}) })
  local record = mgr:drawRecords()[1]
  Assert.equal(record.actorId, "map:61:object:0")
  Assert.equal(record.spriteId, 99)
  Assert.equal(record.facing, "south")
  Assert.equal(record.pose, "idle")
  Assert.isTrue(record.visible)
  Assert.equal(record.world.y, 0)
end

function T.draw_records_reuse_live_slots_and_clear_stale_tail()
  local mgr, eventState = manager({
    object({ objectEventId = 0 }),
    object({ objectEventId = 1, eventFlag = 401, spriteId = 34, x = 4 }),
  })
  local records = mgr:drawRecords()
  local first = records[1]
  local second = records[2]

  eventState:setFlag(401)
  mgr:step(1)
  local fewer = mgr:drawRecords()

  Assert.isTrue(fewer == records, "the record array is reusable")
  Assert.isTrue(fewer[1] == first, "a live actor keeps its record slot")
  Assert.isNil(fewer[2], "removed actors do not remain in the reused tail")
  Assert.equal(fewer[1].actorId, "map:61:object:0")
  Assert.equal(fewer[1].world.x, mgr:getById("map:61:object:0").worldX)
  Assert.isTrue(second ~= fewer[1], "distinct actors do not share a record")

  mgr:setPosition("map:61:object:0", { fieldX = 4, fieldZ = 3 })
  local moved = mgr:drawRecords()
  Assert.isTrue(moved[1] == first)
  Assert.equal(moved[1].world.x, mgr:getById("map:61:object:0").worldX, "reused records receive current actor values")
end

function T.dispose_unsubscribes_from_the_event_state()
  local mgr, eventState = manager({ object({ eventFlag = 401 }) })
  mgr:dispose()
  eventState:setFlag(401)
  mgr:step(1)
  Assert.equal(#mgr:drawRecords(), 0)
end

function T.dispose_releases_every_published_map()
  local mgr, _, assets = manager({ object({ objectEventId = 0 }) })
  mgr:enterMap(runtimeMap({ object({ objectEventId = 1, spriteId = 34 }) }, 62), FieldEventState.new())
  mgr:enterMap(runtimeMap({ object({ objectEventId = 2, spriteId = 29 }) }, 63), FieldEventState.new())

  mgr:dispose()

  Assert.equal(assets:total(), 0, "disposing multiple maps releases every actor visual")
  Assert.isNil(next(mgr.maps), "disposing multiple maps removes every published map")
end

return { tests = T }
