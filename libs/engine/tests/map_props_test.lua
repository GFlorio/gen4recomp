-- MapProps + MapDoor tests: the door/model lookup. A MapProps facade over a
-- scene's building placements resolves a field coordinate to the door of the
-- building placed there -- field coordinate -> building placement ->
-- ModelInstance -> semantic door animation -- without ever leaking NARC ids,
-- animation resource numbers, NSBCA, or animation-list slots. The lookup is
-- strict: the door resolves to the placement whose model footprint (its
-- model-space AABB under the placement transform) contains the door tile's
-- world centre; a tile contained by no placement resolves nothing, and a
-- tile contained by two placements raises. Only DOOR-kind (behavior 105)
-- warp tiles resolve; stairs, directional warps, and generic warps return
-- nil (their choreography is separate policy). Doors over static buildings
-- (no animated instance) resolve but animate nothing.

local Assert = require("tests.support.Assert")
local TilePermissions = require("tests.support.TilePermissions")
local Matrix4 = require("libs.math.src.Matrix4")
local FieldGrid = require("libs.engine.src.FieldGrid")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")
local NitroModelFixture = require("tests.support.NitroModelFixture")
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

-- A placement record in the scene shape: transform + the model-space AABB
-- (footprint) the loader stamps from the model's geometry.
local function placement(index, modelKey, wx, wz, halfExtent)
  return {
    placementIndex = index,
    modelKey = modelKey,
    transform = Matrix4.translate(wx, 0, wz),
    bounds = halfExtent and {
      minX = -halfExtent,
      maxX = halfExtent,
      minY = -halfExtent,
      maxY = halfExtent,
      minZ = -halfExtent,
      maxZ = halfExtent,
    } or nil,
  }
end

-- The default door fixture scene: the door model (a 2x2-tile footprint) is
-- placed exactly at the door tile (4,14)'s centre; a larger building sits at
-- the origin, far from the door tile. The door instance is animated
-- (NitroModelFixture carries door.open/door.close); the building has no
-- animated instance (static).
local function doorScene()
  local wx, wz = tileCenterWorld(4, 14)
  local placements = {
    placement(0, "fixture:building", 0, 0, 4),
    placement(1, "fixture:door", wx, wz, 1),
  }
  local instances = {
    [1] = ModelInstance.new(NitroModelFixture.doorDefinition()),
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

function T.door_at_uses_the_footprint_not_the_distance()
  local wx, wz = tileCenterWorld(4, 14)
  -- The nearest placement (0.65 tiles away) has a tiny footprint that does
  -- not reach the tile; the farther building's footprint contains it.
  local placements = {
    placement(0, "fixture:door", wx + 0.65, wz - 0.26, 0.5),
    placement(1, "fixture:building", wx - 2.5, wz + 2.5, 4),
  }
  local instances = {
    [1] = ModelInstance.new(NitroModelFixture.doorDefinition()),
  }
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    controller = MapPropAnimationController.new(),
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.placementIndex, 1, "containment decides, not proximity")
end

function T.door_at_resolves_a_static_door_when_no_animated_model_is_placed()
  local props = doorScene()
  -- Drop the door model's instance: the door resolves but animates nothing.
  props.instances = {}
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.modelKey, "fixture:door")
  Assert.isNil(door.instance)
  Assert.isNil(door:isFinished())
end

function T.door_at_returns_nil_without_a_containing_placement()
  local props = doorScene()
  -- Remove the door placement entirely: the distant static building is NOT
  -- the door, and the lookup must not silently animate it.
  props.placements = { placement(0, "fixture:building", 0, 0, 4) }
  props.instances = {}
  Assert.isNil(props:doorAt(doorMap(), 4, 14), "no footprint contains the door tile")
end

function T.door_at_raises_when_two_placements_contain_the_tile()
  local wx, wz = tileCenterWorld(4, 14)
  local props = MapProps.new({
    placements = {
      placement(0, "fixture:door", wx, wz, 1),
      placement(1, "fixture:door2", wx, wz, 1),
    },
    instances = {},
    controller = MapPropAnimationController.new(),
  })
  throwsCode("MAP_PROP_AMBIGUOUS_DOOR", function()
    return props:doorAt(doorMap(), 4, 14)
  end)
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
  local closeOnly = NitroModelFixture.doorDefinition({
    NitroModelFixture.doorCloseClip(),
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
  props.instances = {}
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  door:close()
  Assert.isNil(door:isFinished())
end

-- ---- scripted props -----------------------------------------------------

function T.prop_resolves_an_animated_placement_by_index()
  local props, controller, instances = doorScene()
  local prop = assert(props:prop(1))
  Assert.equal(prop.instance, instances[1])
  Assert.equal(prop.modelKey, "fixture:door")
  Assert.equal(prop.placementIndex, 1)

  -- The generic scripted surface: play by role or clip name, stop, pause,
  -- resume, direction, and the HGSS completion check.
  prop:play("door.open", { loopMode = "once" })
  local list = controller:animationsFor(instances[1])
  Assert.equal(#list, 1)
  Assert.equal(list[1].name, "DoorOpen")
  Assert.isFalse(prop:isFinished("door.open"))
  for _ = 1, 7 do
    instances[1]:updateFixed()
  end
  Assert.isTrue(prop:isFinished("door.open"))
  prop:stop("door.open")
  Assert.equal(#controller:animationsFor(instances[1]), 0)
end

function T.prop_play_accepts_clip_names_and_options()
  local props, controller, instances = doorScene()
  local prop = assert(props:prop(1))
  prop:play("DoorOpen", { ratioFx = 0x2000, direction = -1 })
  local attachment = instances[1].animationState:attachments("joint")[1]
  Assert.equal(attachment.ratioFx, 0x2000)
  Assert.equal(attachment.player.deltaFx, -4096)
end

function T.prop_pause_resume_and_direction()
  local props, controller, instances = doorScene()
  local prop = assert(props:prop(1))
  prop:play("door.open")
  prop:pause("door.open")
  local attachment = instances[1].animationState:attachments("joint")[1]
  Assert.isTrue(attachment.player.paused)
  prop:resume("door.open")
  Assert.isFalse(attachment.player.paused)
  prop:setDirection("door.open", -1)
  Assert.equal(attachment.player.deltaFx, -4096)
end

function T.prop_is_finished_is_nil_before_any_play()
  local props = doorScene()
  local prop = assert(props:prop(1))
  Assert.isNil(prop:isFinished("door.open"))
end

function T.prop_for_a_static_placement_is_a_noop_handle()
  local props = doorScene()
  local prop = assert(props:prop(0))
  Assert.isNil(prop.instance)
  prop:play("idle")
  prop:stop("idle")
  prop:pause("idle")
  Assert.isNil(prop:isFinished("idle"))
  Assert.deepEqual(prop:animationsFor(), {})
end

function T.prop_returns_nil_for_unknown_placement()
  local props = doorScene()
  Assert.isNil(props:prop(5))
end

function T.prop_animations_for_lists_the_playing_clips()
  local props, controller, instances = doorScene()
  local prop = assert(props:prop(1))
  Assert.deepEqual(prop:animationsFor(), {})
  prop:play("door.open")
  prop:play("door.close")
  local list = prop:animationsFor()
  Assert.equal(#list, 2)
  Assert.equal(list[1].name, "DoorClose")
  Assert.equal(list[2].name, "DoorOpen")
end

function T.prop_raises_for_an_unknown_animation()
  local props = doorScene()
  local prop = assert(props:prop(1))
  throwsCode("MAP_PROP_ANIM_UNKNOWN", function()
    prop:play("no.such.animation")
  end)
end

return T
