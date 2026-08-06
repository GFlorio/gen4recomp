-- FieldActorManager tests freeze the object-actor lifecycle: flag visibility,
-- surface resolution, the occupancy index, idempotent map entry, balanced
-- visual acquire/release, and one deferred-movement report per actor.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldEventState = require("libs.engine.src.FieldEventState")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local POLICY = { variableSpriteRange = { first = 101, last = 117 }, staticMovementCodes = { 0 } }

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
  return TerrainSurface.new({ plates = {
    { id = 0, minX = 0, minZ = 0, maxX = 32, maxZ = 32,
      normal = { x = 0, y = 1, z = 0 }, distance = 0, slopeClass = "flat" },
    { id = 1, minX = 8, minZ = 0, maxX = 32, maxZ = 32,
      normal = { x = 0, y = 1, z = 0 }, distance = 4, slopeClass = "flat" },
    { id = 2, minX = 20, minZ = 0, maxX = 24, maxZ = 32,
      normal = { x = 0, y = 1, z = 0 }, distance = 0, slopeClass = "flat" },
  } })
end

local function object(overrides)
  local event = {
    index = 0, objectEventId = 0, spriteId = 99, movement = 0, type = 0,
    eventFlag = 0, scriptId = 1, facingDirection = "south", facingDirectionRaw = 1,
    param0 = 0, param1 = 0, param2 = 0, xRange = 0, yRange = 0, x = 2, z = 3, y = 0,
  }
  for key, value in pairs(overrides or {}) do event[key] = value end
  return event
end

local function runtimeMap(objects, mapId)
  return {
    mapId = mapId or 61,
    coordinateOrigin = { x = 0, z = 0 },
    permissions = {
      containsLocal = function(_, x, z) return x >= 0 and x < 40 and z >= 0 and z < 32 end,
    },
    terrain = terrain(),
    fieldData = { events = { objects = objects, background = {}, warps = {}, coordinates = {} } },
  }
end

-- Stands in for FieldActorAssetProvider: same acquire/release/knows contract,
-- with a reference tally so leaks are visible to the tests.
local function fakeAssets(known)
  return {
    references = {},
    knows = function(self, spriteId) return known[spriteId] == true end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = { spriteId = spriteId, mapModelId = spriteId } }
    end,
    release = function(self, spriteId)
      local count = self.references[spriteId] or 0
      assert(count > 0, "unbalanced release of spriteId " .. spriteId)
      self.references[spriteId] = count - 1
    end,
    total = function(self)
      local sum = 0
      for _, count in pairs(self.references) do sum = sum + count end
      return sum
    end,
  }
end

local function manager(objects, opts)
  opts = opts or {}
  local assets = opts.assets or fakeAssets({ [99] = true, [34] = true, [29] = true })
  local eventState = opts.eventState or FieldEventState.new()
  local traced = {}
  local mgr = FieldActorManager.new({
    assets = assets, policy = POLICY,
    trace = function(record) traced[#traced + 1] = record end,
  })
  local map = opts.map or runtimeMap(objects)
  mgr:enterMap(map, eventState)
  return mgr, eventState, assets, traced, map
end

function T.visible_objects_become_actors_and_flagged_ones_do_not()
  local eventState = FieldEventState.new({ flags = { [413] = true } })
  local mgr = manager({
    object({ objectEventId = 0, eventFlag = 401 }),
    object({ objectEventId = 1, spriteId = 34, eventFlag = 413, x = 4 }),
  }, { eventState = eventState })
  Assert.notNil(mgr:getById("map:61:object:0"))
  Assert.isNil(mgr:getById("map:61:object:1"))
  Assert.equal(#mgr:drawRecords(0), 1)
end

function T.actor_resolves_position_surface_and_world_anchor()
  local mgr = manager({ object({ x = 9, z = 3 }) })
  local actor = mgr:getById("map:61:object:0")
  Assert.equal(actor.fieldX, 9)
  Assert.equal(actor.fieldZ, 3)
  -- Both plates cover x=9; the raw event Y hint selects the lower one.
  Assert.equal(actor.surfaceId, 0)
  Assert.equal(actor.worldY, 0)
end

function T.raw_event_y_hint_selects_the_stacked_surface()
  local mgr = manager({ object({ x = 9, z = 3, y = 4 * 16 }) })
  Assert.equal(mgr:getById("map:61:object:0").surfaceId, 1)
end

function T.actor_off_the_terrain_is_fatal()
  throwsCode("ACTOR_SURFACE_MISSING", function() manager({ object({ x = 35, z = 3 }) }) end)
end

function T.equally_near_surfaces_are_ambiguous_rather_than_guessed()
  throwsCode("ACTOR_SURFACE_AMBIGUOUS", function() manager({ object({ x = 21, z = 3 }) }) end)
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

function T.uncompiled_sprite_is_fatal()
  throwsCode("ACTOR_VISUAL_MISSING", function() manager({ object({ spriteId = 148 }) }) end)
end

function T.variable_sprite_is_reported_as_unresolved()
  throwsCode("ACTOR_SPRITE_UNRESOLVED", function() manager({ object({ spriteId = 101 }) }) end)
end

function T.occupancy_is_keyed_by_map_cell_and_surface()
  local mgr = manager({ object({ x = 9, z = 3 }) })
  Assert.isTrue(mgr:isOccupied(61, 9, 3, 0))
  Assert.isFalse(mgr:isOccupied(61, 9, 3, 1))
  Assert.isFalse(mgr:isOccupied(61, 8, 3, 0))
  Assert.isFalse(mgr:isOccupied(60, 9, 3, 0))
  Assert.isFalse(mgr:isOccupied(61, 9, 3, 0, "map:61:object:0"))
  Assert.equal(mgr:getAt(61, 9, 3, 0).actorId, "map:61:object:0")
end

function T.setting_a_flag_removes_draw_and_occupancy_on_one_tick()
  local mgr, eventState, assets = manager({ object({ eventFlag = 401 }) })
  Assert.equal(assets:total(), 1)
  eventState:setFlag(401)
  -- Nothing changes until the manager's fixed-tick boundary.
  Assert.notNil(mgr:getById("map:61:object:0"))
  mgr:step(1)
  Assert.isNil(mgr:getById("map:61:object:0"))
  Assert.equal(#mgr:drawRecords(0), 0)
  Assert.isFalse(mgr:isOccupied(61, 2, 3, 0))
  Assert.equal(assets:total(), 0)
end

function T.clearing_a_flag_restores_the_actor_at_its_source_state()
  local eventState = FieldEventState.new({ flags = { [401] = true } })
  local mgr, _, assets = manager({ object({ eventFlag = 401, facingDirection = "west" }) },
    { eventState = eventState })
  Assert.isNil(mgr:getById("map:61:object:0"))
  eventState:clearFlag(401)
  mgr:step(1)
  local actor = mgr:getById("map:61:object:0")
  Assert.notNil(actor)
  Assert.equal(actor.facing, "west")
  Assert.isTrue(mgr:isOccupied(61, 2, 3, 0))
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
  local mgr, eventState, assets, _, map = manager({ object({}) })
  mgr:enterMap(map, eventState)
  Assert.equal(#mgr:drawRecords(0), 1)
  Assert.equal(assets:total(), 1)
end

function T.leaving_a_map_releases_every_visual()
  local mgr, _, assets = manager({ object({}) })
  mgr:leaveMap(61)
  Assert.equal(assets:total(), 0)
  Assert.isNil(mgr:getById("map:61:object:0"))
  Assert.isFalse(mgr:isOccupied(61, 2, 3, 0))
end

function T.repeated_map_round_trips_do_not_leak_actors_or_visuals()
  local mgr, eventState, assets, _, map = manager({ object({}) })
  for _ = 1, 3 do
    mgr:leaveMap(61)
    mgr:enterMap(map, eventState)
  end
  Assert.equal(#mgr:drawRecords(0), 1)
  Assert.equal(assets:total(), 1)
  mgr:dispose()
  Assert.equal(assets:total(), 0)
end

function T.two_maps_stay_independent_during_a_transition()
  local assets = fakeAssets({ [99] = true, [34] = true })
  local eventState = FieldEventState.new()
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  mgr:enterMap(runtimeMap({ object({}) }, 61), eventState)
  mgr:enterMap(runtimeMap({ object({ spriteId = 34 }) }, 60), eventState)
  Assert.isTrue(mgr:isOccupied(61, 2, 3, 0))
  Assert.isTrue(mgr:isOccupied(60, 2, 3, 0))
  mgr:leaveMap(61)
  Assert.isFalse(mgr:isOccupied(61, 2, 3, 0))
  Assert.isTrue(mgr:isOccupied(60, 2, 3, 0))
end

function T.non_static_movement_is_deferred_once_per_actor()
  local _, _, _, traced = manager({ object({ movement = 14 }) })
  Assert.equal(#traced, 1)
  Assert.equal(traced[1].kind, "actor.movement_deferred")
  Assert.equal(traced[1].actorId, "map:61:object:0")
  Assert.equal(traced[1].movement, 14)
end

function T.static_movement_is_not_reported()
  local _, _, _, traced = manager({ object({ movement = 0 }) })
  Assert.equal(#traced, 0)
end

function T.pose_clock_advances_only_for_visible_actors()
  local mgr, eventState = manager({ object({ eventFlag = 401 }) })
  mgr:step(1)
  mgr:step(2)
  Assert.equal(mgr:getById("map:61:object:0").poseTick, 2)
  eventState:setFlag(401)
  mgr:step(3)
  eventState:clearFlag(401)
  -- A restored actor starts a fresh pose clock rather than resuming a hidden one.
  mgr:step(4)
  Assert.equal(mgr:getById("map:61:object:0").poseTick, 1)
end

function T.draw_records_are_presentation_neutral()
  local mgr = manager({ object({}) })
  local record = mgr:drawRecords(0.5)[1]
  Assert.equal(record.actorId, "map:61:object:0")
  Assert.equal(record.spriteId, 99)
  Assert.equal(record.facing, "south")
  Assert.equal(record.pose, "idle")
  Assert.equal(record.alpha, 1)
  Assert.isTrue(record.visible)
  Assert.equal(record.world.y, 0)
end

function T.dispose_unsubscribes_from_the_event_state()
  local mgr, eventState = manager({ object({ eventFlag = 401 }) })
  mgr:dispose()
  eventState:setFlag(401)
  mgr:step(1)
  Assert.equal(#mgr:drawRecords(0), 0)
end

return T
