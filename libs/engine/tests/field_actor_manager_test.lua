-- FieldActorManager tests freeze the object-actor lifecycle: flag visibility,
-- surface resolution, the occupancy index, idempotent map entry, and balanced
-- visual acquire/release.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldObjectActor = require("libs.engine.src.FieldObjectActor")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

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
---@class FieldActorManagerTest.Manager : FieldActorManager
---@field enterMap fun(self: FieldActorManagerTest.Manager, map: RuntimeFieldMap, state: FieldEventState)
---@field leaveMap fun(self: FieldActorManagerTest.Manager, mapId: integer)
---@field dispose fun(self: FieldActorManagerTest.Manager)
---@field _destroy fun(self: FieldActorManagerTest.Manager, entry: table, actor: table)
---@field collectSpriteIds fun(self: FieldActorManagerTest.Manager, out: table)
---@field drawRecords fun(self: FieldActorManagerTest.Manager): table[]
---@field getById fun(self: FieldActorManagerTest.Manager, actorId: string): table?
---@field getAt fun(self: FieldActorManagerTest.Manager, mapId: integer, x: integer, z: integer, surface: integer): table?
---@field isOccupied fun(self: FieldActorManagerTest.Manager, mapId: integer, x: integer, z: integer, surface: integer, except: string?): boolean
---@field visualRevision fun(self: FieldActorManagerTest.Manager): integer
---@field setPosition fun(self: FieldActorManagerTest.Manager, actorId: string, position: table)
---@field hide fun(self: FieldActorManagerTest.Manager, actorId: string)

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
    movement = 0,
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

local function runtimeMap(objects, mapId)
  local map = {
    mapId = mapId or 61,
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
      return { spriteId = spriteId, visual = { spriteId = spriteId } }
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
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY }) --[[@as FieldActorManagerTest.Manager]]
  local map = opts.map or runtimeMap(objects)
  mgr:enterMap(map, eventState)
  return mgr, eventState, assets, map
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
  local mgr = manager({ object({ x = 9, z = 3, y = 4 * 16 }) })
  Assert.equal(mgr:getById("map:61:object:0").surfaceId, 1)
end

function T.actor_off_the_terrain_is_fatal()
  throwsCode("ACTOR_SURFACE_MISSING", function()
    manager({ object({ x = 35, z = 3 }) })
  end)
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
  Assert.equal(assert(mgr:getAt(61, 2, 3, 0)).actorId, "map:61:object:0")
  eventState:setFlag(402)
  mgr:step(1)
  Assert.isNil(mgr:getById("map:61:object:1"))
  Assert.equal(assert(mgr:getAt(61, 2, 3, 0), "the solid occupant survived").actorId, "map:61:object:0")
  Assert.isTrue(mgr:isOccupied(61, 2, 3, 0))
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
  })
  assets:acquire(99)
  entry.actors[imposter.actorId] = imposter
  entry.order[#entry.order + 1] = imposter
  mgr:_destroy(entry, imposter)
  Assert.equal(assert(mgr:getAt(61, 2, 3, 0), "the occupant entry survived").actorId, "map:61:object:0")
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

function T.occupancy_is_keyed_by_map_cell_and_surface()
  local mgr = manager({ object({ x = 9, z = 3 }) })
  Assert.isTrue(mgr:isOccupied(61, 9, 3, 0))
  Assert.isFalse(mgr:isOccupied(61, 9, 3, 1))
  Assert.isFalse(mgr:isOccupied(61, 8, 3, 0))
  Assert.isFalse(mgr:isOccupied(60, 9, 3, 0))
  Assert.isFalse(mgr:isOccupied(61, 9, 3, 0, "map:61:object:0"))
  Assert.equal(assert(mgr:getAt(61, 9, 3, 0)).actorId, "map:61:object:0")
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
  Assert.isFalse(mgr:isOccupied(61, 2, 3, 0))
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
  local mgr, eventState, assets, map = manager({ object({}) })
  mgr:enterMap(map, eventState)
  Assert.equal(#mgr:drawRecords(), 1)
  Assert.equal(assets:total(), 1)
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
  local mgr, _, assets = manager({ object({}) })
  mgr:leaveMap(61)
  Assert.equal(assets:total(), 0)
  Assert.isNil(mgr:getById("map:61:object:0"))
  Assert.isFalse(mgr:isOccupied(61, 2, 3, 0))
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
    occupancy = function(x, z, surface)
      local occupant = mgr:getAt(map.mapId, x, z, surface)
      return occupant and occupant.actorId or nil
    end,
  })
  return p
end

-- Script integration: the actor world resolves numeric map-object indexes
-- through the manager's current map, and scripted show/hide reach the draw
-- records.
function T.script_actor_world_resolves_map_indexes_and_visibility()
  local ScriptActorWorld = require("libs.engine.src.script.ScriptActorWorld")
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
-- a silent occupancy overwrite.
function T.script_set_position_cannot_overwrite_occupancy()
  local mgr = manager({
    object({ objectEventId = 0, x = 2, z = 3 }),
    object({ objectEventId = 1, x = 8, z = 3 }),
  })
  local _ = mgr:getById("map:61:object:1")
  throwsCode("ACTOR_OCCUPANCY_CONFLICT", function()
    mgr:setPosition("map:61:object:0", { fieldX = 8, fieldZ = 3 })
  end)
  Assert.equal(assert(mgr:getAt(61, 8, 3, 0), "the occupant entry survived the conflict").actorId, "map:61:object:1")
  Assert.equal(assert(mgr:getAt(61, 2, 3, 0), "the mover kept its old cell").actorId, "map:61:object:0")
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
  Assert.equal(assert(mgr:getAt(61, 2, 3, 0), "the mover kept its old cell").actorId, "map:61:object:0")
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
  Assert.equal(assert(mgr:getAt(61, 2, 3, 0), "the mover kept its old cell").actorId, "map:61:object:0")
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
  Assert.equal(assert(mgr:getAt(61, 9, 3, 1), "occupancy rekeys on the new surface").actorId, "map:61:object:0")
  Assert.isNil(mgr:getAt(61, 9, 3, 0), "no occupancy on the old surface at the destination")
  Assert.isNil(mgr:getAt(61, 2, 3, 0), "the old cell is vacated")
end

-- Without an explicit worldY the actor stays on its current surface when it
-- covers the destination: scripted movement keeps the actor on its plate.
function T.script_set_position_without_world_y_stays_on_the_current_surface()
  local mgr = manager({ object({ objectEventId = 0, x = 2, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  mgr:setPosition("map:61:object:0", { fieldX = 9, fieldZ = 3 })
  Assert.equal(actor.surfaceId, 0, "the current surface covers the destination and is preserved")
  Assert.equal(actor.worldY, 0)
  Assert.equal(assert(mgr:getAt(61, 9, 3, 0)).actorId, "map:61:object:0")
end

-- Hidden actors stay solid for collision and report hidden snapshots: the
-- two views never contradict.
function T.hidden_actors_report_hidden_snapshots_and_stay_solid()
  local ScriptActorWorld = require("libs.engine.src.script.ScriptActorWorld")
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
  Assert.isTrue(mgr:isOccupied(61, 2, 3, 0), "hidden actors remain solid for collision")
  Assert.equal(world:snapshot("map:61:object:0").visible, false, "hide_object reflects in snapshots")
  world:show("map:61:object:0")
  Assert.equal(world:snapshot("map:61:object:0").visible, true, "show_object restores snapshot visibility")
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
  Assert.isFalse(mgr:isOccupied(61, 9, 3, 0))
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
  Assert.isTrue(mgr:isOccupied(61, 9, 3, 0))
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

return { tests = T }
