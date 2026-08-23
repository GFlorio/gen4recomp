-- Production-composed transition contracts. These scenarios use real
-- ROM-derived maps, props, warps, player choreography, and transition state;
-- audio is observed only through the recording host boundary.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldTransitionProfile = require("libs.engine.src.FieldTransitionProfile")

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
local LAB_DOOR_ANCHOR = { fieldX = 4, fieldZ = 14 }
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
    Assert.isFalse(game.runtime.player.motion == "climbing", "horizontal stairs must not use an in-place climb")
    local transition = game:waitForTransition()
    Assert.equal(game.runtime.transition.profileId, 3, "indoor stairs retain fixed profile 3")
    Assert.equal(game.runtime.transition.sourceKind, "stairs", "the trigger remains a stair transition")
    Assert.isTrue(hasEffect(game, "SEQ_SE_DP_KAIDAN2"), "the stair exit emits the source sequence")
    Assert.equal(transition.destination.mapSymbol, HOUSE_2F)
    Assert.equal(transition.destination.player.fieldX, HOUSE_WARP.fieldX - 1)
    Assert.equal(transition.destination.player.fieldZ, HOUSE_WARP.fieldZ + 1)
    Assert.equal(transition.destination.player.facing, "east")
  end)
end

function T.tests.numeric_profiles_have_source_owned_dispatch()
  withGame(TOWN, function(game)
    local transition = game.runtime.transition
    Assert.notNil(transition, "the production field runtime must own a transition coordinator")
    for profile = 0, 8 do
      local family = FieldTransitionProfile.ROUTINE_FAMILIES[profile]
      Assert.notNil(family, "every numeric profile needs a source-owned routine family")
      Assert.notNil(family.exit, "every numeric profile needs an exit routine")
      Assert.notNil(family.enter, "every numeric profile needs an enter routine")
    end
    Assert.isNil(FieldTransitionProfile.ROUTINE_FAMILIES.panel, "scripted panel warps are not numeric profiles")
    Assert.equal(
      type(transition.presentationStatus),
      "function",
      "transition presentation must be observable without rendering"
    )
  end)
end

function T.tests.standard_fade_uses_source_substeps()
  withGame(TOWN, function(game)
    beginTownDoor(game)
    local transition = game.runtime.transition
    Assert.equal(type(transition.presentationStatus), "function", "transition presentation status is required")
    local samples = {}
    game:advanceUntil("first source fade tick", function()
      return transition.fade ~= nil and transition.fade.updates > 0
    end, 120)
    samples[#samples + 1] = transition:presentationStatus().coefficient
    for _ = 1, 2 do
      game:step()
      local status = transition:presentationStatus()
      samples[#samples + 1] = status.coefficient
    end
    Assert.deepEqual(samples, { 5, 10, 16 })
    Assert.equal(transition:presentationStatus().completed, true)
  end)
end

function T.tests.door_fade_waits_for_source_ingress_and_preserves_anchor()
  withGame(TOWN, function(game)
    beginTownDoor(game)
    local transition = game.runtime.transition
    Assert.isTrue(hasEffect(game, "SEQ_SE_DP_DOOR_OPEN"), "door audio follows the selected source animation")
    Assert.notNil(transition.sourceDoor, "the production transition must resolve the source door")
    Assert.equal(type(transition.presentationStatus), "function", "door choreography status is required")
    local first = transition:presentationStatus()
    Assert.equal(first.phase, "door_open", "door ingress owns the first transition phase")
    Assert.isNil(transition.resolution, "destination preparation waits for source door ingress")
    game:advanceUntil("source door ingress completes", function(snapshot)
      return transition.resolution ~= nil
    end, 120)
    Assert.equal(transition.resolution.fieldX, LAB_FLOOR.fieldX)
    Assert.equal(transition.resolution.fieldZ, LAB_DOOR_ANCHOR.fieldZ)
    Assert.equal(transition:presentationStatus().entryAction, "step_down")
    local completed = game:waitForTransition()
    Assert.deepEqual(
      { completed.destination.player.fieldX, completed.destination.player.fieldZ },
      { LAB_FLOOR.fieldX, LAB_FLOOR.fieldZ }
    )
    Assert.isFalse(completed.destination.player.fieldZ < LAB_FLOOR.fieldZ, "door movement must not overshoot")
  end)
end

function T.tests.transition_post_state_reanchors_player_and_camera()
  withGame(TOWN, function(game)
    enterHouse(game)
    game:moveTo(HOUSE_WARP)
    game:step({ direction = "west" })
    local transition = game:waitForTransition()
    local camera = assert(game.runtime.camera, "the production runtime must own a destination camera")
    Assert.notNil(camera.target, "post-transition camera target must be renderer-consumed state")
    Assert.notNil(camera.eye, "post-transition camera eye must be renderer-consumed state")
    Assert.equal(transition.destination.player.worldY, game.runtime.player.worldY)
    Assert.equal(camera.previousTarget.x, camera.target.x)
    Assert.equal(camera.previousTarget.y, camera.target.y)
    Assert.equal(camera.previousTarget.z, camera.target.z)
  end)
end

function T.tests.profile_presentation_is_not_a_generic_black_warp()
  withGame(TOWN, function(game)
    local transition = game.runtime.transition
    local family4 = FieldTransitionProfile.ROUTINE_FAMILIES[4]
    local family5 = FieldTransitionProfile.ROUTINE_FAMILIES[5]
    Assert.isFalse(family4.exit == family5.exit)
    Assert.isFalse(family4.enter == family5.enter)
    Assert.equal(family4.fadeMode, "environment_0x10")
    Assert.equal(family5.fadeColor, 0x7FFF)
    Assert.equal(
      type(transition.presentationStatus),
      "function",
      "profile presentation must expose fade type and color"
    )
  end)
end

function T.tests.escalator_uses_prop_audio_and_source_movement_actions()
  withGame(TOWN, function(game)
    local transition = game.runtime.transition
    Assert.equal(type(transition.profileState), "function", "the escalator profile must be observable")
    local state = assert(transition:profileState(2), "the escalator profile must be observable")
    Assert.equal(state.exitSound, "SEQ_SE_DP_ESUKA")
    Assert.equal(state.pauseAction, "pause_animation")
    Assert.equal(state.resumeAction, "resume_animation")
    Assert.equal(state.horizontalAction, "walk_slow")
    Assert.isTrue(state.requiresPropAnimation)
  end)
end

function T.tests.vertical_profiles_keep_distinct_vectors_and_entry_actions()
  withGame(TOWN, function(game)
    local transition = game.runtime.transition
    for profile, expected in pairs({
      [7] = { exit = "ladder_up", enter = "walk_normal_north", dy = 8192 },
      [8] = { exit = "ladder_down", enter = "walk_normal_south", dy = -8192 },
    }) do
      Assert.equal(type(transition.profileState), "function", "profile state must be observable")
      local state = assert(transition:profileState(profile), "profile state must be observable")
      Assert.equal(state.exitVector.dy, expected.dy)
      Assert.equal(state.enterAction, expected.enter)
      Assert.equal(state.exitSound, "SEQ_SE_DP_KAIDAN2")
      Assert.equal(state.exitRoutine, expected.exit)
    end
  end)
end

return T
