-- Production-composed transition contracts. These scenarios use real
-- ROM-derived maps, props, warps, player choreography, and transition state;
-- audio is observed only through the recording host boundary.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "transition", "door", "profile" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_2F = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local TOWN_DOOR = { fieldX = 684, fieldZ = 393 }
local TOWN_DOOR_APPROACH = { fieldX = 684, fieldZ = 394 }
local LAB_FLOOR = { fieldX = 4, fieldZ = 13 }
local HOUSE_WARP = { fieldX = 3, fieldZ = 3 }

local function withGame(map, fn)
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", map = map, save = "fresh" })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "transition acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function beginTownDoor(game)
  game:moveTo(TOWN_DOOR_APPROACH)
  game:move("north")
  Assert.equal(game.runtime.transition.phase, "fade_out", "the production door input must start a transition")
end

local function hasEffect(game, sequence)
  for _, effect in ipairs(game:hostEffects()) do
    if effect == "audio:" .. sequence then
      return true
    end
  end
  return false
end

function T.tests.door_open_animation_emits_source_selected_sound_on_start()
  withGame(TOWN, function(game)
    beginTownDoor(game)
    Assert.isTrue(
      hasEffect(game, "SEQ_SE_DP_DOOR_OPEN"),
      "the source door animation and its ROM-selected open sound must begin together"
    )
    Assert.notNil(game.runtime.transition.sourceDoor, "the production transition must resolve the source door")
  end)
end

function T.tests.door_transition_uses_up_then_down_and_lands_adjacent()
  withGame(TOWN, function(game)
    beginTownDoor(game)
    local transition = game:waitForTransition()
    local player = transition.destination.player
    Assert.deepEqual({ player.fieldX, player.fieldZ }, { LAB_FLOOR.fieldX, LAB_FLOOR.fieldZ })
    Assert.isFalse(player.fieldZ < LAB_FLOOR.fieldZ, "door completion must not overshoot past the lab floor")
    Assert.equal(transition.source.player.fieldX, TOWN_DOOR.fieldX)
    Assert.equal(transition.source.player.fieldZ, TOWN_DOOR.fieldZ)
  end)
end

local function enterHouse(game)
  game:moveTo({ fieldX = 695, fieldZ = 397 })
  game:step({ direction = "north" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
end

function T.tests.player_house_stairs_remain_fixed_profile_three_indoors()
  withGame(TOWN, function(game)
    enterHouse(game)
    game:moveTo(HOUSE_WARP)
    game:step({ direction = "west" })
    Assert.equal(game.runtime.player.motion, "climbing", "the source stair path owns held movement")
    local transition = game:waitForTransition()
    Assert.equal(game.runtime.transition.profileId, 3, "indoor stairs retain fixed profile 3")
    Assert.equal(game.runtime.transition.sourceKind, "stairs", "the trigger remains a stair transition")
    Assert.isTrue(hasEffect(game, "SEQ_SE_DP_KAIDAN2"), "the stair exit emits the source sequence")
    Assert.equal(transition.destination.mapSymbol, HOUSE_2F)
    Assert.equal(transition.destination.player.fieldX, HOUSE_WARP.fieldX)
    Assert.equal(transition.destination.player.fieldZ, HOUSE_WARP.fieldZ + 1)
  end)
end

return T
