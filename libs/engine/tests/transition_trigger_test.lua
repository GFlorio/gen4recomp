-- TransitionTrigger tests cover the HGSS metatile-behavior classification
-- (kind/triggerMode/required directions per warp behavior byte) and the two
-- evaluation paths from field_control.c: inputPath mirrors
-- FieldSystem_CheckMapTransition (the blocked-facing door and the
-- direction-gated standing warps), stepPath mirrors FieldSystem_CheckTransition
-- (north/panel/ladder-down/escalator standing warps).

local Assert = require("tests.support.Assert")
local TilePermissions = require("tests.support.TilePermissions")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")

local T = {}

local BEHAVIOR = TransitionTrigger.BEHAVIOR

-- Stub runtime map: 32x32 permission grid addressed by "fieldX:fieldZ" tiles.
-- tiles entries are { behavior = byte, blocked = boolean }; defaults are
-- behavior 0 (plain floor) and walkable.
local function runtimeMap(originX, originZ, warps, tiles)
  return {
    mapId = 61,
    coordinateOrigin = { x = originX, z = originZ },
    fieldData = { events = { warps = warps } },
    permissions = TilePermissions.new(tiles),
  }
end

local function warp(x, z)
  return { index = 0, x = x, z = z, destinationMapId = 60, destinationWarpId = 0, y = 0 }
end

-- Classification ----------------------------------------------------------

function T.door_behavior_classifies_facing()
  local trigger = assert(TransitionTrigger.classify(BEHAVIOR.DOOR))
  Assert.notNil(trigger)
  Assert.equal(trigger.kind, "door")
  Assert.equal(trigger.triggerMode, "facing")
  Assert.equal(trigger.evaluatesOn, "input")
  Assert.isTrue(TransitionTrigger.matchesDirection(trigger, "north"))
  Assert.isTrue(TransitionTrigger.matchesDirection(trigger, "east"))
end

function T.stairs_behaviors_classify_standing_with_direction()
  local east = assert(TransitionTrigger.classify(BEHAVIOR.WARP_STAIRS_EAST))
  Assert.equal(east.kind, "stairs")
  Assert.equal(east.triggerMode, "standing")
  Assert.isTrue(TransitionTrigger.matchesDirection(east, "east"))
  Assert.isFalse(TransitionTrigger.matchesDirection(east, "west"))
  local west = assert(TransitionTrigger.classify(BEHAVIOR.WARP_STAIRS_WEST))
  Assert.equal(west.kind, "stairs")
  Assert.isTrue(TransitionTrigger.matchesDirection(west, "west"))
  Assert.isFalse(TransitionTrigger.matchesDirection(west, "east"))
end

function T.warp_and_entrance_directionals_classify_with_gates()
  local gates = {
    [BEHAVIOR.WARP_EAST] = "east",
    [BEHAVIOR.WARP_WEST] = "west",
    [BEHAVIOR.WARP_SOUTH] = "south",
    [BEHAVIOR.WARP_ENTRANCE_EAST] = "east",
    [BEHAVIOR.WARP_ENTRANCE_WEST] = "west",
    [BEHAVIOR.WARP_ENTRANCE_SOUTH] = "south",
  }
  for behavior, direction in pairs(gates) do
    local trigger = assert(TransitionTrigger.classify(behavior))
    Assert.equal(trigger.kind, "directional", "kind for behavior " .. behavior)
    Assert.equal(trigger.triggerMode, "standing")
    Assert.equal(trigger.evaluatesOn, "input")
    Assert.isTrue(TransitionTrigger.matchesDirection(trigger, direction))
    Assert.isFalse(
      TransitionTrigger.matchesDirection(trigger, "north"),
      "wrong-direction gate for behavior " .. behavior
    )
  end
end

function T.north_warps_panel_and_ladder_down_classify_generic_step()
  for _, behavior in ipairs({
    BEHAVIOR.WARP_NORTH,
    BEHAVIOR.WARP_ENTRANCE_NORTH,
    BEHAVIOR.WARP_PANEL,
    BEHAVIOR.LADDER_DOWN,
  }) do
    local trigger = assert(TransitionTrigger.classify(behavior))
    Assert.equal(trigger.kind, "generic", "kind for behavior " .. behavior)
    Assert.equal(trigger.triggerMode, "standing")
    Assert.equal(trigger.evaluatesOn, "step")
    Assert.isTrue(TransitionTrigger.matchesDirection(trigger, "north"), "generic warps gate no direction")
    Assert.isTrue(TransitionTrigger.matchesDirection(trigger, "west"))
  end
end

function T.ladder_north_south_classify_directional_input()
  local north = assert(TransitionTrigger.classify(BEHAVIOR.LADDER_NORTH))
  Assert.equal(north.kind, "directional")
  Assert.equal(north.triggerMode, "standing")
  Assert.equal(north.evaluatesOn, "input")
  Assert.isTrue(TransitionTrigger.matchesDirection(north, "north"))
  Assert.isFalse(TransitionTrigger.matchesDirection(north, "south"))
  local south = assert(TransitionTrigger.classify(BEHAVIOR.LADDER_SOUTH))
  Assert.isTrue(TransitionTrigger.matchesDirection(south, "south"))
  Assert.isFalse(TransitionTrigger.matchesDirection(south, "north"))
end

function T.escalators_classify_directional_step_with_east_west_gate()
  for _, behavior in ipairs({ BEHAVIOR.ESCALATOR, BEHAVIOR.ESCALATOR_FLIP_FACE }) do
    local trigger = assert(TransitionTrigger.classify(behavior))
    Assert.equal(trigger.kind, "directional")
    Assert.equal(trigger.evaluatesOn, "step")
    Assert.isTrue(TransitionTrigger.matchesDirection(trigger, "east"))
    Assert.isTrue(TransitionTrigger.matchesDirection(trigger, "west"))
    Assert.isFalse(TransitionTrigger.matchesDirection(trigger, "north"))
  end
end

function T.unrecognized_behaviors_do_not_classify()
  for _, behavior in ipairs({ 0, 1, 2, 3, 63, 104, 112, 255 }) do
    Assert.isNil(TransitionTrigger.classify(behavior), "behavior " .. behavior .. " must not classify")
  end
end

-- inputPath (FieldSystem_CheckMapTransition) --------------------------------

function T.facing_door_triggers_from_blocked_facing_tile()
  local warps = { warp(4, 14) }
  local map = runtimeMap(0, 0, warps, {
    ["4:14"] = { behavior = BEHAVIOR.DOOR, blocked = true },
  })
  local trigger = assert(TransitionTrigger.inputPath(map, 4, 13, "south"))
  Assert.equal(trigger.kind, "door")
  Assert.equal(trigger.triggerMode, "facing")
  Assert.equal(trigger.behavior, BEHAVIOR.DOOR)
  Assert.equal(assert(trigger.warp), warps[1])
  -- One-record contract: the returned trigger is a single record carrying the
  -- full classification (including ladder, which doors classify as false) plus
  -- the attached warp data. No field may be dropped or duplicated when the
  -- warp is attached.
  Assert.equal(trigger.evaluatesOn, "input")
  Assert.isFalse(trigger.ladder)
  Assert.deepEqual(trigger.requiredDirections, {})
  local keyCount = 0
  for _ in pairs(trigger) do
    keyCount = keyCount + 1
  end
  Assert.equal(keyCount, 7, "trigger must be exactly classification + warp + behavior")
end

function T.facing_door_requires_the_facing_tile_to_be_blocked()
  local map = runtimeMap(0, 0, { warp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.DOOR, blocked = false },
  })
  Assert.isNil(TransitionTrigger.inputPath(map, 4, 13, "south"))
end

function T.facing_door_requires_door_behavior_on_the_facing_tile()
  local map = runtimeMap(0, 0, { warp(4, 14) }, {
    ["4:14"] = { behavior = 0, blocked = true },
  })
  Assert.isNil(TransitionTrigger.inputPath(map, 4, 13, "south"))
end

function T.facing_tile_warp_with_non_door_behavior_does_not_trigger()
  local map = runtimeMap(0, 0, { warp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.WARP_STAIRS_EAST, blocked = true },
  })
  Assert.isNil(TransitionTrigger.inputPath(map, 4, 13, "south"))
end

function T.standing_directional_triggers_when_the_gate_matches()
  -- The lab door pattern: warp tile (4,14) is WARP_ENTRANCE_SOUTH with the
  -- blocked wall tile (4,15) ahead; the player stands on the warp tile and
  -- faces south.
  local warps = { warp(4, 14) }
  local map = runtimeMap(0, 0, warps, {
    ["4:14"] = { behavior = BEHAVIOR.WARP_ENTRANCE_SOUTH },
    ["4:15"] = { blocked = true },
  })
  local trigger = assert(TransitionTrigger.inputPath(map, 4, 14, "south"))
  Assert.equal(trigger.kind, "directional")
  Assert.equal(trigger.behavior, BEHAVIOR.WARP_ENTRANCE_SOUTH)
  Assert.equal(assert(trigger.warp), warps[1])
end

function T.standing_directional_gate_rejects_wrong_direction()
  local map = runtimeMap(0, 0, { warp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.WARP_ENTRANCE_SOUTH },
    ["4:15"] = { blocked = true },
  })
  Assert.isNil(TransitionTrigger.inputPath(map, 4, 14, "north"))
end

function T.standing_stairs_triggers_with_its_direction_gate()
  local warps = { warp(3, 3) }
  local map = runtimeMap(0, 0, warps, {
    ["3:3"] = { behavior = BEHAVIOR.WARP_STAIRS_WEST },
    ["2:3"] = { blocked = true },
  })
  local trigger = assert(TransitionTrigger.inputPath(map, 3, 3, "west"))
  Assert.equal(trigger.kind, "stairs")
  Assert.equal(trigger.behavior, BEHAVIOR.WARP_STAIRS_WEST)
  Assert.equal(assert(trigger.warp), warps[1])
  Assert.isNil(TransitionTrigger.inputPath(map, 3, 3, "east"))
end

function T.input_path_requires_a_blocked_facing_tile_for_standing_triggers()
  local map = runtimeMap(0, 0, { warp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.WARP_ENTRANCE_SOUTH },
  })
  Assert.isNil(TransitionTrigger.inputPath(map, 4, 14, "south"))
end

function T.standing_door_triggers_without_a_direction_gate()
  local warps = { warp(4, 14) }
  local map = runtimeMap(0, 0, warps, {
    ["4:14"] = { behavior = BEHAVIOR.DOOR },
    ["5:14"] = { blocked = true },
  })
  local trigger = assert(TransitionTrigger.inputPath(map, 4, 14, "east"))
  Assert.equal(trigger.kind, "door")
  Assert.equal(assert(trigger.warp), warps[1])
end

function T.ladder_triggers_standing_without_a_blocked_facing_tile()
  local warps = { warp(4, 14) }
  local map = runtimeMap(0, 0, warps, {
    ["4:14"] = { behavior = BEHAVIOR.LADDER_NORTH },
  })
  local trigger = assert(TransitionTrigger.inputPath(map, 4, 14, "north"))
  Assert.equal(trigger.kind, "directional")
  Assert.equal(assert(trigger.warp), warps[1])
end

function T.ladder_gate_failure_blocks_all_further_input_checks()
  -- HGSS: the ladder branches return FALSE without falling through, so a
  -- failed ladder gate suppresses even a facing-tile door.
  local map = runtimeMap(0, 0, { warp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.LADDER_NORTH },
    ["4:15"] = { behavior = BEHAVIOR.DOOR, blocked = true },
  })
  Assert.isNil(TransitionTrigger.inputPath(map, 4, 14, "south"))
end

function T.input_path_does_not_fire_step_only_behaviors()
  for _, behavior in ipairs({ BEHAVIOR.WARP_NORTH, BEHAVIOR.WARP_PANEL, BEHAVIOR.ESCALATOR }) do
    local map = runtimeMap(0, 0, { warp(4, 14) }, {
      ["4:14"] = { behavior = behavior },
      ["4:15"] = { blocked = true },
    })
    Assert.isNil(TransitionTrigger.inputPath(map, 4, 14, "north"), "input path must not fire behavior " .. behavior)
  end
end

function T.input_path_without_a_warp_at_the_standing_tile_returns_nil()
  local map = runtimeMap(0, 0, { warp(5, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.WARP_ENTRANCE_SOUTH },
    ["4:15"] = { blocked = true },
  })
  Assert.isNil(TransitionTrigger.inputPath(map, 4, 14, "south"))
end

-- stepPath (FieldSystem_CheckTransition) ------------------------------------

function T.north_warp_triggers_on_step_in_any_facing()
  local warps = { warp(4, 14) }
  local map = runtimeMap(0, 0, warps, {
    ["4:14"] = { behavior = BEHAVIOR.WARP_NORTH },
  })
  local trigger = assert(TransitionTrigger.stepPath(map, 4, 14, "south"))
  Assert.equal(trigger.kind, "generic")
  Assert.equal(trigger.behavior, BEHAVIOR.WARP_NORTH)
  Assert.equal(assert(trigger.warp), warps[1])
  Assert.notNil(TransitionTrigger.stepPath(map, 4, 14, "north"))
end

function T.panel_and_ladder_down_trigger_on_step()
  for _, behavior in ipairs({ BEHAVIOR.WARP_PANEL, BEHAVIOR.LADDER_DOWN }) do
    local map = runtimeMap(0, 0, { warp(4, 14) }, {
      ["4:14"] = { behavior = behavior },
    })
    local trigger = assert(TransitionTrigger.stepPath(map, 4, 14, "north"))
    Assert.equal(trigger.kind, "generic")
  end
end

function T.escalator_triggers_on_step_when_facing_west_or_east()
  local map = runtimeMap(0, 0, { warp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.ESCALATOR },
  })
  Assert.notNil(TransitionTrigger.stepPath(map, 4, 14, "east"))
  Assert.notNil(TransitionTrigger.stepPath(map, 4, 14, "west"))
  Assert.isNil(TransitionTrigger.stepPath(map, 4, 14, "north"))
end

function T.step_path_does_not_fire_input_only_behaviors()
  for _, behavior in ipairs({
    BEHAVIOR.DOOR,
    BEHAVIOR.WARP_STAIRS_EAST,
    BEHAVIOR.WARP_ENTRANCE_SOUTH,
    BEHAVIOR.LADDER_NORTH,
  }) do
    local map = runtimeMap(0, 0, { warp(4, 14) }, {
      ["4:14"] = { behavior = behavior },
    })
    Assert.isNil(TransitionTrigger.stepPath(map, 4, 14, "south"), "step path must not fire behavior " .. behavior)
  end
end

function T.step_path_requires_a_warp_at_the_standing_tile()
  local map = runtimeMap(0, 0, { warp(5, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.WARP_NORTH },
  })
  Assert.isNil(TransitionTrigger.stepPath(map, 4, 14, "north"))
end

function T.step_path_ignores_unrecognized_behaviors()
  local map = runtimeMap(0, 0, { warp(4, 14) }, {
    ["4:14"] = { behavior = 0 },
  })
  Assert.isNil(TransitionTrigger.stepPath(map, 4, 14, "north"))
end

-- Unknown direction ---------------------------------------------------------

function T.unknown_direction_is_rejected()
  local map = runtimeMap(0, 0, { warp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.DOOR, blocked = true },
  })
  local err = Assert.throws(function()
    TransitionTrigger.inputPath(map, 4, 13, "sideways")
  end)
  Assert.equal(err.code, "ACTOR_FACING_INVALID")
end

return { tests = T }
