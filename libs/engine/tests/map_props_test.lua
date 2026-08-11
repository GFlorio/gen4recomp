-- MapProps + MapDoor tests: the door/model lookup. A MapProps facade over a
-- scene's building placements resolves a field coordinate to the door of the
-- building placed there -- field coordinate -> building placement ->
-- ModelInstance -> semantic door animation -- without ever leaking NARC ids,
-- animation resource numbers, NSBCA, or animation-list slots. Ownership is
-- precomputed once when the scene is assembled: the assembly enumerates the
-- door tiles (the DOOR-kind behavior-105 tiles of the permission grid) and
-- resolves each to the placement whose pivot (transform translation) is
-- NEAREST the tile centre -- the predicate verified against the real ROM,
-- where door models are planar slabs whose AABB does not contain the tile
-- centre (New Bark member 26: x[-0.3,0.0] z[0.0,0.0]) and an AABB test
-- resolves the wrong static building. doorAt is then an O(1) index lookup:
-- no placement scan, no matrix inversion, no epsilon on the hot path.
-- Ambiguity (two placements tied for one door tile) and missing coverage (a
-- door tile with no placement) are data failures diagnosed once at assembly,
-- not per lookup. The index is authoritative: a tile it does not cover
-- resolves nothing, and mutating the placement list after assembly changes
-- nothing. Only DOOR-kind warp tiles resolve; stairs, directional warps, and
-- generic warps return nil. Doors over static buildings (no animated
-- instance) resolve but animate nothing. Pure domain module under test.
--
-- The playback surface is the COLLAPSED animation object graph:
-- MapProps carries no controller. MapDoor plays through the instance and
-- retains the returned play handle on the tile's index entry (entry.animation
-- replaces the old currentRole string); isFinished reads that handle, so the
-- finish state never depends on the disposable MapDoor identity. SceneProp
-- keeps play/stop/isFinished; pause/resume/setDirection/animationsFor do not
-- exist -- no production caller uses them.

local Assert = require("tests.support.Assert")
local TilePermissions = require("tests.support.TilePermissions")
local Matrix4 = require("libs.math.src.Matrix4")
local FieldGrid = require("libs.engine.src.FieldGrid")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")
local NitroModelFixture = require("tests.support.NitroModelFixture")
local ModelInstance = require("libs.engine.src.ModelInstance")
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
-- (footprint) the loader stamps from the model's geometry. The precomputed
-- ownership index resolves by pivot (transform translation), so bounds no
-- longer participate in the door lookup.
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
-- animated instance (static). `doorTiles` is what the scene assembly
-- precomputes ownership over: the permission cell's DOOR-behavior tiles as
-- local indices (0..31).
local function doorScene()
  local wx, wz = tileCenterWorld(4, 14)
  local placements = {
    placement(0, "fixture:building", 0, 0, 4),
    placement(1, "fixture:door", wx, wz, 1),
  }
  local instances = {
    [1] = ModelInstance.new(NitroModelFixture.doorDefinition()),
  }
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    doorTiles = { { x = 4, z = 14 } },
  })
  return props, instances
end

local function doorMap()
  return runtimeMap(0, 0, { doorWarp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.DOOR, blocked = true },
  })
end

-- ---- resolution ---------------------------------------------------------

function T.door_at_resolves_the_door_tile_to_its_animated_door()
  local props, instances = doorScene()
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

-- The regression shape from the real ROM: the door model is a planar slab
-- whose pivot sits near the door tile but whose footprint does NOT contain
-- the tile centre, while a larger building's footprint contains it. The
-- door tile belongs to the placement whose pivot is nearest; the AABB
-- containment test resolves the wrong (static) building on New Bark.
function T.door_at_resolves_the_placement_whose_pivot_is_nearest()
  local wx, wz = tileCenterWorld(4, 14)
  local placements = {
    placement(0, "fixture:door", wx + 0.65, wz - 0.26, 0.5),
    placement(1, "fixture:building", wx - 2.5, wz + 2.5, 4),
  }
  local instances = {
    [0] = ModelInstance.new(NitroModelFixture.doorDefinition()),
  }
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.placementIndex, 0, "the nearest pivot decides, not containment")
  Assert.equal(door.modelKey, "fixture:door")
  Assert.equal(door.instance, instances[0])
end

function T.door_at_consults_only_the_precomputed_index()
  local props = doorScene()
  local first = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(first.placementIndex, 1)
  -- Ownership is precomputed once at assembly: mutating the placement list
  -- afterwards cannot change what the tile resolves to -- doorAt must not
  -- rescan placements per lookup.
  props.placements = { placement(0, "fixture:building", 0, 0, 4) }
  local second = assert(props:doorAt(doorMap(), 4, 14), "the door still resolves from the precomputed index")
  Assert.equal(second.placementIndex, 1, "the precomputed index decides, not a per-call scan")
end

function T.door_at_returns_nil_for_a_tile_the_index_does_not_cover()
  -- The index is authoritative: a door warp whose tile the assembly did not
  -- enumerate resolves nothing, even when a placement's footprint contains
  -- it. The production assembly enumerates every door-behavior tile, so
  -- this only fires on an assembly bug -- loudly nil, never a scanned
  -- guess.
  local wx, wz = tileCenterWorld(4, 14)
  local props = MapProps.new({
    placements = { placement(0, "fixture:door", wx, wz, 1) },
    instances = {},
    doorTiles = { { x = 5, z = 5 } },
  })
  Assert.isNil(props:doorAt(doorMap(), 4, 14))
end

function T.door_at_resolves_a_static_placement_when_no_door_model_is_placed()
  -- With the door model absent, the tile still resolves to its nearest
  -- placement -- here the static building (nil instance, no-op playback).
  -- The pivot predicate is total; the assembly diagnoses only a door tile
  -- with no placement at all. HGSS's static interior doors resolve and
  -- animate nothing the same way.
  local props = MapProps.new({
    placements = { placement(0, "fixture:building", 0, 0, 4) },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14), "the nearest placement resolves")
  Assert.equal(door.placementIndex, 0)
  Assert.equal(door.modelKey, "fixture:building")
  Assert.isNil(door.instance)
  Assert.isNil(door:isFinished())
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

function T.door_at_finish_state_does_not_depend_on_handle_identity()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  for _ = 1, 7 do
    instances[1]:updateFixed()
  end
  -- The tile's door state is not private to the handle that played it: a
  -- fresh resolution of the same tile observes the finished open. The
  -- retained play handle lives on the tile's index entry, so no handle
  -- identity carries the finish state.
  local fresh = assert(props:doorAt(doorMap(), 4, 14))
  Assert.isTrue(fresh:isFinished(), "a freshly resolved handle sees the finished role")
end

function T.assembly_raises_when_two_placements_own_the_same_door_tile()
  local wx, wz = tileCenterWorld(4, 14)
  throwsCode("MAP_PROP_AMBIGUOUS_DOOR", function()
    return MapProps.new({
      placements = {
        placement(0, "fixture:door", wx, wz, 1),
        placement(1, "fixture:door2", wx, wz, 1),
      },
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
end

function T.assembly_raises_when_two_placements_tie_for_a_door_tile()
  local wx, wz = tileCenterWorld(4, 14)
  -- Two placements equidistant from the door tile (here: the same pivot)
  -- are ambiguous regardless of their footprints: a pivot tie is diagnosed
  -- once at assembly, not at the first lookup.
  local slab = {
    minX = -0.3,
    maxX = 0,
    minY = -0.3,
    maxY = 0.3,
    minZ = 0,
    maxZ = 0,
  }
  local function door(index, key)
    return {
      placementIndex = index,
      modelKey = key,
      transform = Matrix4.translate(wx, 0, wz),
      bounds = slab,
    }
  end
  throwsCode("MAP_PROP_AMBIGUOUS_DOOR", function()
    return MapProps.new({
      placements = { door(0, "fixture:door"), door(1, "fixture:door2") },
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
end

function T.assembly_raises_when_a_door_tile_has_no_placement()
  -- Missing coverage is a data failure diagnosed once at assembly: a door
  -- tile the scene assembles with no building placement must not silently
  -- resolve nothing at transition time. (Corpus check: every real map with
  -- door tiles places at least one building, so the raise never fires on
  -- real data.)
  throwsCode("MAP_PROP_UNCOVERED_DOOR", function()
    return MapProps.new({
      placements = {},
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
end

-- ---- playback -----------------------------------------------------------

function T.open_plays_the_door_open_role_once_and_finishes()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  local joint = instances[1].animationState:attachments("joint")
  Assert.equal(#joint, 1)
  Assert.equal(joint[1].clip.name, "DoorOpen")
  Assert.deepEqual(joint[1].clip.semanticNames, { "door.open" })
  Assert.isFalse(door:isFinished())
  for _ = 1, 7 do
    instances[1]:updateFixed()
  end
  Assert.isTrue(door:isFinished(), "the opened door reaches the last frame")
end

function T.close_stops_the_open_and_plays_close()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  instances[1]:updateFixed()
  door:close()
  local joint = instances[1].animationState:attachments("joint")
  Assert.equal(#joint, 1)
  Assert.equal(joint[1].clip.name, "DoorClose")
  door:open()
  joint = instances[1].animationState:attachments("joint")
  Assert.equal(#joint, 1)
  Assert.equal(joint[1].clip.name, "DoorOpen")
end

function T.is_finished_is_nil_before_any_play()
  local props = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.isNil(door:isFinished())
end

function T.open_raises_when_the_door_model_lacks_the_role()
  local props, instances = doorScene()
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

-- The collapsed door surface: the tile's index entry retains
-- the PLAY HANDLE from instance:play -- not a role string -- so the finish
-- state is read off the live attachment and survives every fresh resolution.
function T.door_open_retains_the_play_handle_on_the_tile()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.isNil(door.entry.currentRole, "the retained entry no longer stores a role string")
  Assert.isNil(door.entry.animation, "nothing plays before the first open")
  door:open()
  local handle = door.entry.animation
  Assert.notNil(handle, "the tile's entry retains the play handle")
  Assert.equal(handle.clip.name, "DoorOpen")
  Assert.isTrue(
    instances[1].animationState:attachments("joint")[1] == handle,
    "the retained handle is the live attachment"
  )
  door:close()
  Assert.equal(door.entry.animation.clip.name, "DoorClose", "the retained handle follows the played role")
end

-- Replaying a role replaces the previous play of that door: the retained
-- handle is stopped and a fresh one attached, so one door has one playing
-- attachment (the controller-identity behavior survives without a
-- controller).
function T.replaying_the_role_replaces_the_previous_play()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  local first = door.entry.animation
  Assert.notNil(first, "the tile retains the first play handle")
  instances[1]:updateFixed()
  door:open()
  local second = door.entry.animation
  Assert.notNil(second, "the tile retains the replayed play handle")
  Assert.isFalse(first == second, "the replay attaches a fresh handle")
  Assert.equal(#instances[1].animationState:attachments("joint"), 1, "one door has one playing attachment")
  Assert.equal(second.player.frameFx, 0, "the replay restarts the clip")
end

-- ---- scripted props -----------------------------------------------------

function T.prop_resolves_an_animated_placement_by_index()
  local props, instances = doorScene()
  local prop = assert(props:prop(1))
  Assert.equal(prop.instance, instances[1])
  Assert.equal(prop.modelKey, "fixture:door")
  Assert.equal(prop.placementIndex, 1)

  -- The generic scripted surface: play by role or clip name, stop, and the
  -- HGSS completion check.
  local handle = prop:play("door.open", { loopMode = "once" })
  Assert.equal(type(handle), "table", "prop:play returns the instance's attachment handle")
  local joint = instances[1].animationState:attachments("joint")
  Assert.equal(#joint, 1)
  Assert.equal(joint[1].clip.name, "DoorOpen")
  Assert.isFalse(prop:isFinished("door.open"))
  for _ = 1, 7 do
    instances[1]:updateFixed()
  end
  Assert.isTrue(prop:isFinished("door.open"))
  prop:stop("door.open")
  Assert.equal(#instances[1].animationState:attachments("joint"), 0)
end

function T.prop_play_accepts_clip_names_and_options()
  local props, instances = doorScene()
  local prop = assert(props:prop(1))
  prop:play("DoorOpen", { ratioFx = 0x2000, direction = -1 })
  local attachment = instances[1].animationState:attachments("joint")[1]
  Assert.equal(attachment.ratioFx, 0x2000)
  Assert.equal(attachment.player.deltaFx, -4096)
end

function T.prop_is_finished_is_nil_before_any_play()
  local props = doorScene()
  local prop = assert(props:prop(1))
  Assert.isNil(prop:isFinished("door.open"))
end

-- The generic prop surface is exactly play/stop/isFinished: pause, resume,
-- setDirection, and animationsFor have no production caller anywhere (the
-- debugger overlay and inventory tooling do not exist on this branch), so
-- the collapsed surface does not carry them.
function T.prop_surface_is_play_stop_and_is_finished_only()
  local props = doorScene()
  local prop = assert(props:prop(1))
  Assert.isNil(prop.pause, "pause has no caller and must not exist")
  Assert.isNil(prop.resume, "resume has no caller and must not exist")
  Assert.isNil(prop.setDirection, "setDirection has no caller and must not exist")
  Assert.isNil(prop.animationsFor, "animationsFor has no caller and must not exist")
end

function T.prop_for_a_static_placement_is_a_noop_handle()
  local props = doorScene()
  local prop = assert(props:prop(0))
  Assert.isNil(prop.instance)
  Assert.isNil(prop:play("idle"))
  Assert.isNil(prop:stop("idle"))
  Assert.isNil(prop:isFinished("idle"))
end

function T.prop_returns_nil_for_unknown_placement()
  local props = doorScene()
  Assert.isNil(props:prop(5))
end

function T.prop_raises_for_an_unknown_animation()
  local props = doorScene()
  local prop = assert(props:prop(1))
  throwsCode("MAP_PROP_ANIM_UNKNOWN", function()
    prop:play("no.such.animation")
  end)
end

function T.prop_resolves_from_the_precomputed_index()
  local props = doorScene()
  local prop = assert(props:prop(1))
  Assert.equal(prop.placementIndex, 1)
  -- The placement index is precomputed at assembly like the door index:
  -- prop() must not rescan the placement list per call.
  props.placements = { placement(0, "fixture:building", 0, 0, 4) }
  local again = assert(props:prop(1), "the placement index decides, not a per-call scan")
  Assert.equal(again.placementIndex, 1)
  Assert.equal(again.modelKey, "fixture:door")
end

return T
