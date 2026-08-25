-- Production-composed transition contracts. These scenarios use real
-- ROM-derived maps, props, warps, player choreography, and transition state;
-- audio is observed only through the recording host boundary.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

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
local HOUSE_WARP = { fieldX = 3, fieldZ = 3 }

-- These coordinates are source facts, not engine policy. The two HGSS
-- releases use different arrival cells for the same named transitions.
local VERSION_FACTS = {
  heartgold = {
    house2fArrival = { fieldX = 3, fieldZ = 4 },
    labFloor = { fieldX = 4, fieldZ = 13 },
    labDoorAnchor = { fieldX = 4, fieldZ = 14 },
  },
  soulsilver = {
    house2fArrival = { fieldX = 3, fieldZ = 4 },
    labFloor = { fieldX = 4, fieldZ = 14 },
    labDoorAnchor = { fieldX = 4, fieldZ = 14 },
  },
}

local function withGame(map, fn, fieldOptions)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({
      versionId = versionId,
      map = map,
      save = "fresh",
      fieldOptions = fieldOptions,
    })
    game:advanceDialogue()
    local ok, err = xpcall(function()
      fn(game)
      Assert.equal(game:renderAttempts(), 0, "transition acceptance must stop before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

local function factsFor(game)
  return assert(VERSION_FACTS[game.versionId], "missing transition facts for " .. game.versionId)
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

local function effectCount(game, sequence)
  local count = 0
  for _, effect in ipairs(game:hostEffects()) do
    if effect == "audio:" .. sequence then
      count = count + 1
    end
  end
  return count
end

local function enterHouse(game)
  game:moveTo({ fieldX = 695, fieldZ = 397 })
  game:step({ direction = "north" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
end

-- The House 1F stair tile is a source WARP_STAIRS_WEST metatile: HGSS gates
-- it on the player's next input direction while standing on the tile, not on
-- the approach direction that reached it (pret/pokeheartgold
-- src/field/field_control.c FieldSystem_CheckMapTransition,
-- MetatileBehavior_IsWarpStairsWest requires DIR_WEST). Walking onto the
-- landing from the south and then idling never fires the transition; the
-- player must press west once settled on the stair tile.
local function stepOntoHouseStairs(game)
  game:moveTo({ fieldX = HOUSE_WARP.fieldX, fieldZ = HOUSE_WARP.fieldZ + 1 })
  game:step({ direction = "north" })
  game:advanceUntil("player reaches the stair landing", function(snapshot)
    return snapshot.player.motion == "idle"
      and snapshot.player.fieldX == HOUSE_WARP.fieldX
      and snapshot.player.fieldZ == HOUSE_WARP.fieldZ
  end, 60)
  game:step({ direction = "west" })
end

-- Explicit post-opening fixture for tests whose purpose is the House 1F
-- stair profile, not the source Mom scene itself: run the source Mom scene
-- to completion first (the other lifecycle-safe strategy besides seeding).
-- Seeding the scene variable directly while still on MAP_NEW_BARK is unsafe
-- here: New Bark's own on-frame rule matches the same value 1 for the
-- unrelated friend/Marill scene, which currently faults and keeps
-- restarting. Running the real Mom scene keeps the player inside Player
-- House 1F throughout and never returns to MAP_NEW_BARK's own lifecycle.
local function withPostOpeningHouseGame(fn, fieldOptions)
  withGame(TOWN, function(game)
    enterHouse(game)
    OpeningLifecycle.completeOpeningHouseScene(game)
    fn(game)
  end, fieldOptions)
end

function T.tests.player_house_stairs_remain_fixed_profile_three_indoors()
  withPostOpeningHouseGame(function(game)
    local facts = factsFor(game)
    stepOntoHouseStairs(game)
    Assert.isFalse(game.runtime.player.motion == "climbing", "horizontal stairs must not use an in-place climb")
    local staged = game:advanceUntil("destination stair staging", function(snapshot)
      return snapshot.mapSymbol == HOUSE_2F
    end, 120)
    Assert.deepEqual(
      { staged.player.fieldX, staged.player.fieldZ },
      { facts.house2fArrival.fieldX, facts.house2fArrival.fieldZ },
      "profile three must expose its adjacent arrival tile after the swap"
    )
    game:advanceUntil("destination stair transition completes", function(snapshot)
      return snapshot.mapSymbol == HOUSE_2F
        and snapshot.transition.phase == "idle"
        and snapshot.player.motion == "idle"
        and snapshot.player.fieldX == facts.house2fArrival.fieldX
        and snapshot.player.fieldZ == facts.house2fArrival.fieldZ
    end, 120)
    Assert.equal(game.runtime.transition.profileId, 3, "indoor stairs retain fixed profile 3")
    Assert.equal(game.runtime.transition.sourceKind, "stairs", "the trigger remains a stair transition")
    Assert.isTrue(hasEffect(game, "SEQ_SE_DP_KAIDAN2"), "the stair exit emits the source sequence")
    Assert.deepEqual(
      { game.runtime.player.fieldX, game.runtime.player.fieldZ },
      { facts.house2fArrival.fieldX, facts.house2fArrival.fieldZ },
      "profile three must finish on the real destination arrival tile"
    )
    Assert.equal(game.runtime.player.facing, "east")
    Assert.equal(game.runtime.player.fieldX, facts.house2fArrival.fieldX)
    Assert.equal(game.runtime.player.fieldZ, facts.house2fArrival.fieldZ)
  end, { recordingScriptHosts = true })
end

function T.tests.transition_sounds_are_emitted_once_by_profile_choreography()
  withGame(TOWN, function(game)
    local facts = factsFor(game)
    beginTownDoor(game)
    Assert.equal(effectCount(game, "SEQ_SE_DP_DOOR_OPEN"), 1, "ordinary profile audio must be emitted once")
    game:waitForTransition()
  end, { recordingScriptHosts = true })

  withPostOpeningHouseGame(function(game)
    stepOntoHouseStairs(game)
    game:waitForTransition()
    local stairSoundCount = effectCount(game, "SEQ_SE_DP_KAIDAN2")
    Assert.equal(stairSoundCount, 1, "stair profile audio must be emitted once; got " .. tostring(stairSoundCount))
  end, { recordingScriptHosts = true })
end

function T.tests.standard_fade_exposes_every_source_frame()
  withGame(TOWN, function(game)
    beginTownDoor(game)
    local transition = game.runtime.transition
    Assert.equal(type(transition.presentationStatus), "function", "transition presentation status is required")
    local samples = {}
    for _ = 1, 6 do
      game.runtime:update(1 / 60)
      local status = transition:presentationStatus()
      samples[#samples + 1] = status.coefficient
    end
    Assert.deepEqual(samples, { 2, 5, 7, 10, 13, 16 })
    Assert.equal(transition:presentationStatus().completed, true)
  end)
end

local function fadeTimeline(fieldOptions)
  local timeline = {}
  withGame(TOWN, function(game)
    beginTownDoor(game)
    local transition = game.runtime.transition
    for _ = 1, 120 do
      game.runtime:update(1 / 60)
      local status = transition:presentationStatus()
      timeline[#timeline + 1] = {
        coefficient = status.coefficient,
        mapSymbol = game:snapshot().mapSymbol,
        phase = status.phase,
      }
      if status.phase == "idle" then
        break
      end
    end
    Assert.equal(transition.phase, "idle", "the transition must complete on the source-frame clock")
    Assert.equal(timeline[#timeline].coefficient, 0, "completion must follow fade-in to zero")
  end, fieldOptions)
  return timeline
end

function T.tests.standard_fade_timing_is_independent_of_audio_composition()
  local withoutAudio = fadeTimeline()
  local withAudio = fadeTimeline({ audioHost = "production", audioOutput = FakeAudioOutput.new() })
  Assert.deepEqual(withAudio, withoutAudio, "audio composition must not change fade timing or swap ordering")
end

function T.tests.door_fade_waits_for_source_ingress_and_preserves_anchor()
  withGame(TOWN, function(game)
    local facts = factsFor(game)
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
    Assert.equal(transition.resolution.fieldX, facts.labFloor.fieldX)
    Assert.equal(transition.resolution.fieldX, facts.labDoorAnchor.fieldX)
    Assert.equal(transition.resolution.fieldZ, facts.labDoorAnchor.fieldZ)
    Assert.equal(transition:presentationStatus().entryAction, "step_down")
    local completed = game:waitForTransition()
    Assert.deepEqual(
      { completed.destination.player.fieldX, completed.destination.player.fieldZ },
      { facts.labFloor.fieldX, facts.labFloor.fieldZ }
    )
    Assert.isFalse(completed.destination.player.fieldZ < facts.labFloor.fieldZ, "door movement must not overshoot")
  end, { recordingScriptHosts = true })
end

-- The door choreography's semantic resolution (source door, ingress/egress
-- anchor, destination arrival) is a production capability of `FieldTransition`
-- itself; recording hosts only let a scenario additionally observe the door
-- sound effect. This scenario proves the resolution/anchor/arrival contract
-- holds with no `recordingScriptHosts` composed at all, and with zero
-- graphics allocation.
function T.tests.door_choreography_resolves_headlessly_without_recording_hosts()
  withGame(TOWN, function(game)
    local facts = factsFor(game)
    beginTownDoor(game)
    local transition = game.runtime.transition
    Assert.notNil(transition.sourceDoor, "the production transition must resolve the source door without hosts")
    game:advanceUntil("source door ingress completes", function()
      return transition.resolution ~= nil
    end, 120)
    Assert.equal(transition.resolution.fieldX, facts.labDoorAnchor.fieldX)
    Assert.equal(transition.resolution.fieldZ, facts.labDoorAnchor.fieldZ)
    Assert.equal(transition:presentationStatus().entryAction, "step_down")
    local completed = game:waitForTransition()
    Assert.deepEqual(
      { completed.destination.player.fieldX, completed.destination.player.fieldZ },
      { facts.labFloor.fieldX, facts.labFloor.fieldZ }
    )
  end)
end

function T.tests.transition_post_state_reanchors_player_and_camera()
  withPostOpeningHouseGame(function(game)
    stepOntoHouseStairs(game)
    local transition = game:waitForTransition()
    local camera = assert(game.runtime.camera, "the production runtime must own a destination camera")
    Assert.notNil(camera.target, "post-transition camera target must be renderer-consumed state")
    Assert.notNil(camera.eye, "post-transition camera eye must be renderer-consumed state")
    Assert.equal(transition.destination.player.worldY, game.runtime.player.worldY)
    Assert.equal(camera.previousTarget.x, camera.target.x)
    Assert.equal(camera.previousTarget.y, camera.target.y)
    Assert.equal(camera.previousTarget.z, camera.target.z)
  end, { recordingScriptHosts = true })
end

return T
