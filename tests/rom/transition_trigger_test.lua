-- Real-ROM assertions for the semantic warp trigger classification: the Elm
-- Lab door (WARP_ENTRANCE_SOUTH, standing + facing south), the
-- New Bark doors (DOOR, blocked facing tile), the player-house stairs
-- (WARP_STAIRS_WEST), and the Route 29 north warps (WARP_NORTH, step path).

local Assert = require("tests.support.Assert")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local TransitionTrigger = require("libs.hgss.src.transition.TransitionTrigger")

local T = {}

function T.elms_lab_door_classifies_directional_south_on_real_data(romFs)
  local lab = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local trigger = assert(TransitionTrigger.inputPath(lab, 4, 14, "south"), "facing south on the lab door tile resolves")
  Assert.equal(trigger.kind, "directional")
  Assert.equal(assert(trigger.warp).destinationMapId, 60)
  Assert.isNil(TransitionTrigger.inputPath(lab, 4, 14, "north"), "the gate requires facing south")
  Assert.isNil(
    TransitionTrigger.inputPath(lab, 4, 13, "south"),
    "the walkable door tile ahead is no blocked-facing trigger"
  )
  Assert.isNil(TransitionTrigger.stepPath(lab, 4, 14, "south"), "direction-gated warps never fire on the step path")
end

function T.new_bark_doors_classify_door_on_real_data(romFs)
  local town = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK")
  for _, door in ipairs({
    { x = 684, z = 394, destinationMapId = 61 },
    { x = 695, z = 397, destinationMapId = 63 },
    { x = 679, z = 406, destinationMapId = 65 },
  }) do
    local trigger = assert(TransitionTrigger.inputPath(town, door.x, door.z, "north"), "facing the town door resolves")
    Assert.equal(trigger.kind, "door")
    Assert.equal(assert(trigger.warp).destinationMapId, door.destinationMapId)
  end
  Assert.isNil(TransitionTrigger.stepPath(town, 684, 393, "north"), "doors never fire on the step path")
end

function T.player_house_stairs_classify_stairs_on_real_data(romFs)
  local house1f = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_PLAYER_HOUSE_1F")
  local down = assert(TransitionTrigger.inputPath(house1f, 3, 3, "west"), "facing west on the stairs resolves")
  Assert.equal(down.kind, "stairs")
  Assert.equal(assert(down.warp).destinationMapId, 64)
  Assert.isNil(TransitionTrigger.inputPath(house1f, 3, 3, "east"), "the stairs gate requires facing west")
  Assert.isNil(TransitionTrigger.stepPath(house1f, 3, 3, "west"), "stairs never fire on the step path")

  local house2f = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_PLAYER_HOUSE_2F")
  local up = assert(TransitionTrigger.inputPath(house2f, 3, 4, "west"), "facing west upstairs resolves")
  Assert.equal(up.kind, "stairs")
  Assert.equal(assert(up.warp).destinationMapId, 63)
end

function T.route_29_north_warps_classify_generic_on_real_data(romFs)
  local route29 = RomRuntimeMap.compile(romFs, "MAP_ROUTE_29")
  local trigger =
    assert(TransitionTrigger.stepPath(route29, 626, 389, "south"), "stepping onto the north warp resolves")
  Assert.equal(trigger.kind, "generic")
  Assert.isNil(TransitionTrigger.inputPath(route29, 626, 389, "south"), "north warps never fire on the input path")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
