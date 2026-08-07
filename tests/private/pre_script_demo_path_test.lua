-- Private target facts for the canonical demo path: every cell the exit
-- demonstration walks (spec section 2) is walkable under real ROM terrain
-- and occupancy, and the warp round trip cells behave as the runtime expects.
-- The walk replicates the player's step logic (one held direction per
-- 8-tick step), so a terrain or occupancy surprise here fails loudly.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldScenario = require("libs.engine.src.FieldScenario")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")
local WarpSystem = require("libs.engine.src.WarpSystem")
local actorManifest = require("data.manifests.field_actors")
local scenarioManifest = require("data.manifests.field_scenario")

local T = {}

local LAB = 61
local TOWN = 60

local POLICY = {
  variableSpriteRange = actorManifest.variableSpriteRange,
  variableVarBase = actorManifest.variableVarBase,
}

-- Manager + player on one map under the deterministic scenario. The scenario
-- resolves flags across both target maps, so the reader serves all of them.
local function scene(romFs, mapsById, map)
  local reader = function(mapId)
    return assert(mapsById[mapId], "scenario map " .. mapId .. " not compiled").fieldData
  end
  local eventState = FieldEventState.new()
  FieldScenario.apply(scenarioManifest, eventState, reader)
  local assets = {
    knows = function() return true end,
    acquire = function(_, spriteId) return { spriteId = spriteId, visual = { spriteId = spriteId } } end,
    release = function() end,
  }
  local manager = FieldActorManager.new({ assets = assets, policy = POLICY })
  manager:enterMap(map, eventState)
  return manager, eventState
end

local function playerAt(map, manager, fieldX, fieldZ, facing)
  local localX, localZ = fieldX - map.coordinateOrigin.x, fieldZ - map.coordinateOrigin.z
  local sample = assert(SurfaceResolver.new(map.terrain):resolve({
    localX = localX + 0.5, localZ = localZ + 0.5, currentY = 0,
  }))
  return FieldPlayer.new({
    currentMap = map,
    fieldX = fieldX, fieldZ = fieldZ,
    surfaceId = sample.surfaceId, facing = facing,
    occupancy = function(x, z, surfaceId)
      local occupant = manager:getAt(map.mapId, x, z, surfaceId)
      return occupant and occupant.actorId or nil
    end,
  })
end

-- One full 8-tick step in the held direction; returns false when blocked.
local function step(player, direction)
  player:updateFixed({ pressedDirection = direction, heldDirection = direction })
  if player.motion ~= "walking" then return false end
  for _ = 2, FieldPlayer.WALK_STEP_TICKS do
    player:updateFixed({ heldDirection = direction })
  end
  return true
end

local function walkTo(player, targetX, targetZ)
  local guard = 0
  while (player.fieldX ~= targetX or player.fieldZ ~= targetZ) and guard < 64 do
    guard = guard + 1
    local direction
    if player.fieldZ > targetZ then direction = "north"
    elseif player.fieldZ < targetZ then direction = "south"
    elseif player.fieldX > targetX then direction = "west"
    else direction = "east" end
    assert(step(player, direction), string.format(
      "cell (%d,%d) is not walkable from (%d,%d)", targetX, targetZ, player.fieldX, player.fieldZ))
  end
  Assert.isTrue(player.fieldX == targetX and player.fieldZ == targetZ,
    "walk reached its target cell")
end

function T.the_demo_walk_to_elm_is_walkable_and_elm_blocks(romFs)
  local mapsById = {
    [LAB] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"),
    [TOWN] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK"),
  }
  local map = mapsById[LAB]
  local manager = scene(romFs, mapsById, map)
  local player = playerAt(map, manager, 4, 14, "north")
  -- Spawn -> south of Elm at (6,6).
  walkTo(player, 6, 6)
  Assert.equal(player.fieldX, 6)
  Assert.equal(player.fieldZ, 6)
  -- Pressing north is rejected by Elm's occupied cell: turn only.
  player:updateFixed({ pressedDirection = "north", heldDirection = "north" })
  Assert.equal(player.facing, "north")
  Assert.equal(player.motion, "idle")
  Assert.equal(player.fieldX, 6)
  Assert.equal(player.fieldZ, 6)
  manager:dispose()
end

function T.the_demo_walk_to_the_door_warps_to_town_and_back(romFs)
  local maps = {
    [LAB] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"),
    [TOWN] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK"),
  }
  local lab = maps[LAB]
  local manager = scene(romFs, maps, lab)
  local player = playerAt(lab, manager, 6, 6, "north")
  walkTo(player, 4, 13)
  Assert.equal(player.fieldX, 4)
  Assert.equal(player.fieldZ, 13)
  -- The step into the warp cell (4,14) completes the standing-warp path.
  assert(step(player, "south"), "the lab door cell is walkable")
  Assert.equal(player.fieldX, 4)
  Assert.equal(player.fieldZ, 14)
  Assert.notNil(WarpSystem.findAt(lab, player.fieldX, player.fieldZ))
  manager:dispose()

  -- Town arrival: the door cell (684,393) is permission-blocked with a warp
  -- behind it, so the return trip uses the FACING-warp path: step south off
  -- the door, then face north. This mirrors the runtime's warp semantics.
  local town = maps[TOWN]
  local townManager = scene(romFs, maps, town)
  local townPlayer = playerAt(town, townManager, 684, 393, "south")
  local offDirections = { "east", "west", "south", "north" }
  local moved = false
  for _, direction in ipairs(offDirections) do
    if step(townPlayer, direction) then
      moved = true
      break
    end
  end
  Assert.isTrue(moved, "at least one cell around the town door is walkable")
  Assert.isFalse(townPlayer.fieldX == 684 and townPlayer.fieldZ == 393,
    "the step-off actually moved")
  -- The only walkable neighbor is south (684,394): facing north from there
  -- triggers the blocked-door warp without any step (spec section 8.6 note
  -- on warp semantics).
  Assert.equal(townPlayer.fieldX, 684)
  Assert.equal(townPlayer.fieldZ, 394)
  local facingWarp = WarpSystem.findBlockedFacing(town, 684, 394, "north")
  Assert.notNil(facingWarp, "facing the blocked town door resolves the warp")
  Assert.equal(assert(facingWarp).destinationMapId, 61)
  Assert.notNil(WarpSystem.findAt(town, 684, 393))
  townManager:dispose()
end

function T.the_town_scenario_population_matches_the_demo(romFs)
  local mapsById = {
    [LAB] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"),
    [TOWN] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK"),
  }
  local town = mapsById[TOWN]
  local manager = scene(romFs, mapsById, town)
  local actors = manager:actorsOf(TOWN)
  local expected = { ["map:60:object:1"] = true, ["map:60:object:2"] = true,
    ["map:60:object:5"] = true }
  Assert.equal(#actors, 3)
  for _, actor in ipairs(actors) do
    Assert.isTrue(expected[actor.actorId],
      "unexpected visible town actor " .. actor.actorId)
  end
  Assert.isNil(manager:getById("map:60:object:0"), "the rival stays hidden")
  manager:dispose()
end

return T
