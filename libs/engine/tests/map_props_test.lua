-- MapProps + MapDoor tests: the door/model lookup. A MapProps facade over a
-- scene's building placements resolves a field coordinate to the door of the
-- building placed there -- field coordinate -> building placement ->
-- ModelInstance -> semantic door animation -- without ever leaking NARC ids,
-- animation resource numbers, NSBCA, or animation-list slots. Only DOOR-kind
-- (behavior 105) warp tiles resolve; stairs, directional warps, and generic
-- warps return nil (their choreography is separate policy). Doors over static
-- buildings (no animated instance) resolve but animate nothing.

local Assert = require("tests.support.Assert")
local TilePermissions = require("tests.support.TilePermissions")
local Matrix4 = require("libs.math.src.Matrix4")
local FieldGrid = require("libs.engine.src.FieldGrid")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local GenericModelFixture = require("tests.support.GenericModelFixture")
local ModelInstance = require("libs.engine.src.ModelInstance")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")
local MapProps = require("libs.engine.src.MapProps")

local T = {}

local BEHAVIOR = TransitionTrigger.BEHAVIOR

local function throwsCode(code, fn)
  local ok, result = pcall(fn)
  if ok then
    error("expected a structured " .. code .. " error, got a result")
  end
  Assert.equal(result.code, code)
end

-- Stub runtime map in the transition_trigger_test shape: 32x32 permission
-- grid addressed by "fieldX:fieldZ" tiles.
local function runtimeMap(originX, originZ, warps, tiles)
  return {
    mapId = 61,
    coordinateOrigin = { x = originX, z = originZ },
    fieldData = { events = { warps = warps } },
    permissions = TilePermissions.new(tiles),
  }
end

local function doorWarp(x, z)
  return { index = 0, x = x, z = z, destinationMapId = 60, destinationWarpId = 0, y = 0 }
end

-- World position of a field tile's centre under an origin at (0,0).
local function tileCenterWorld(x, z)
  local wx, wz = FieldGrid.tileCenterToWorld(x, z)
  return wx, wz
end

-- A placement record in the scene shape (transform = 16-element array).
local function placement(index, modelKey, wx, wz)
  return {
    placementIndex = index,
    modelKey = modelKey,
    transform = Matrix4.translate(wx, 0, wz),
  }
end

-- The default door fixture scene: the door model is placed exactly at the
-- door tile (4,14), and a larger building sits a few tiles away. The door
-- instance is animated (GenericModelFixture carries door.open/door.close);
-- the building has no animated instance (static).
local function doorScene()
  local wx, wz = tileCenterWorld(4, 14)
  local placements = {
    placement(0, "fixture:building", 0, 0),
    placement(1, "fixture:door", wx, wz),
  }
  local instances = {
    [1] = ModelInstance.new(GenericModelFixture.doorDefinition()),
  }
  local controller = MapPropAnimationController.new()
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    controller = controller,
  })
  return props, controller, instances
end

local function doorMap()
  return runtimeMap(0, 0, { doorWarp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.DOOR, blocked = true },
  })
end

-- ---- resolution ---------------------------------------------------------

function T.door_at_resolves_the_door_tile_to_its_animated_door()
  local props, _, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.instance, instances[1])
  Assert.equal(door.placementIndex, 1)
  Assert.equal(door.modelKey, "fixture:door")
  Assert.equal(door.x, 4)
  Assert.equal(door.z, 14)
  Assert.equal(assert(door.warp).destinationMapId, 60)
  -- The chain ends at a semantic door animation on the resolved instance.
  Assert.notNil(instances[1].definition:animation("door.open"))
  Assert.notNil(instances[1].definition:animation("door.close"))
end

function T.door_at_returns_nil_without_a_warp_record()
  local props = doorScene()
  local map = doorMap()
  map.fieldData.events.warps = {}
  Assert.isNil(props:doorAt(map, 4, 14))
end

function T.door_at_returns_nil_for_non_door_behaviors()
  local props = doorScene()
  for _, behavior in ipairs({
    BEHAVIOR.WARP_STAIRS_EAST,
    BEHAVIOR.WARP_ENTRANCE_SOUTH,
    BEHAVIOR.WARP_NORTH,
    BEHAVIOR.LADDER_NORTH,
  }) do
    local map = runtimeMap(0, 0, { doorWarp(3, 3) }, {
      ["3:3"] = { behavior = behavior },
    })
    Assert.isNil(props:doorAt(map, 3, 3), "behavior " .. behavior .. " must not resolve a door")
  end
end

function T.door_at_returns_nil_outside_coverage()
  local props = doorScene()
  local map = runtimeMap(0, 0, { doorWarp(40, 40) }, {
    ["40:40"] = { behavior = BEHAVIOR.DOOR },
  })
  Assert.isNil(props:doorAt(map, 40, 40))
end

function T.door_at_picks_the_nearest_placement()
  local wx, wz = tileCenterWorld(4, 14)
  -- The door model sits 0.65 tiles from the tile centre, the building 2.5.
  local placements = {
    placement(0, "fixture:building", wx - 2.5, wz + 2.5),
    placement(1, "fixture:door", wx + 0.65, wz - 0.26),
  }
  local instances = {
    [1] = ModelInstance.new(GenericModelFixture.doorDefinition()),
  }
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    controller = MapPropAnimationController.new(),
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.placementIndex, 1)
  Assert.equal(door.instance, instances[1])
end

function T.door_at_resolves_a_static_door_when_no_animated_model_is_placed()
  local props, _, instances = doorScene()
  -- Drop the door model's placement and instance: the nearest placement is
  -- the static building, and the door resolves without an animation.
  props.placements = { placement(0, "fixture:building", 0, 0) }
  props.instances = {}
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.modelKey, "fixture:building")
  Assert.isNil(door.instance)
  Assert.isNil(door:isFinished())
end

-- ---- playback -----------------------------------------------------------

function T.open_plays_the_door_open_role_once_and_finishes()
  local props, controller, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  local list = controller:animationsFor(instances[1])
  Assert.equal(#list, 1)
  Assert.equal(list[1].name, "DoorOpen")
  Assert.deepEqual(list[1].roles, { "door.open" })
  Assert.isFalse(door:isFinished())
  for _ = 1, 7 do
    instances[1]:updateFixed()
  end
  Assert.isTrue(door:isFinished(), "the opened door reaches the last frame")
end

function T.close_stops_the_open_and_plays_close()
  local props, controller, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  instances[1]:updateFixed()
  door:close()
  local list = controller:animationsFor(instances[1])
  Assert.equal(#list, 1)
  Assert.equal(list[1].name, "DoorClose")
  door:open()
  list = controller:animationsFor(instances[1])
  Assert.equal(#list, 1)
  Assert.equal(list[1].name, "DoorOpen")
end

function T.is_finished_is_nil_before_any_play()
  local props = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.isNil(door:isFinished())
end

function T.open_raises_when_the_door_model_lacks_the_role()
  local props, _, instances = doorScene()
  -- Replace the door instance with a model that only animates door.close.
  local def = GenericModelFixture.doorDefinition()
  local closeOnly = ModelDefinition.new({
    key = def.key,
    sourceBackend = def.sourceBackend,
    nodes = def.nodes,
    meshes = def.meshes,
    materials = def.materials,
    skins = def.skins,
    animations = { assert(def:animation("door.close")) },
    backend = def.backend,
  })
  instances[1] = ModelInstance.new(closeOnly)
  props.instances = { [1] = instances[1] }
  local door = assert(props:doorAt(doorMap(), 4, 14))
  throwsCode("MAP_PROP_ANIM_UNKNOWN", function()
    door:open()
  end)
end

function T.static_door_playback_is_a_noop()
  local props = doorScene()
  props.placements = { placement(0, "fixture:building", 0, 0) }
  props.instances = {}
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  door:close()
  Assert.isNil(door:isFinished())
end

return T
