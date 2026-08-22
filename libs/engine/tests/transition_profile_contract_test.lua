-- Pure transition-profile contracts. These fixtures isolate source-selected
-- door audio and the asymmetric HGSS door movement from ROM loading.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.engine.src.FieldTransition")
local FieldTransitionProfile = require("libs.engine.src.FieldTransitionProfile")

local T = { tests = {} }

-- Environment-selected profiles use the generated semantic map matrix,
-- including an explicit failure for unsupported pairs.
function T.tests.a_d05_02_environment_selection_matches_hgss_matrix()
  local expected = {
    { "cave", "cave", 6 },
    { "cave", "outdoors", 5 },
    { "cave", "building", 6 },
    { "outdoors", "cave", 4 },
    { "outdoors", "building", 6 },
    { "building", "building", 6 },
    { "building", "cave", 0 },
    { "building", "outdoors", 0 },
  }
  for _, pair in ipairs(expected) do
    Assert.equal(FieldTransitionProfile.selectEnvironment(pair[1], pair[2]), pair[3])
  end

  Assert.throws(function()
    FieldTransitionProfile.selectEnvironment("outdoors", "outdoors")
  end, "outdoors-to-outdoors must fail instead of defaulting to a profile")
end

T.tests.transition_profiles_preserve_source_semantics = function()
  Assert.equal(FieldTransitionProfile.fixed(1).profile, 1)
  Assert.equal(FieldTransitionProfile.fixed(3).profile, 3)
  Assert.equal(FieldTransitionProfile.selectEnvironment("building", "building"), 6)
  Assert.equal(FieldTransitionProfile.selectEnvironment("building", "outdoors"), 0)
end

function T.tests.field_transition_consumes_trigger_profile_before_ownership()
  local metadataCalls = 0
  local loader = {
    transitionEnvironment = function(_, mapId)
      metadataCalls = metadataCalls + 1
      Assert.equal(mapId, 60)
      return "building"
    end,
    load = function()
      error("profile selection must not load a destination map", 0)
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = function()
      return {
        destinationMap = { mapId = 60 },
        fieldX = 0,
        fieldZ = 0,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function() end,
    commit = function() end,
  })

  transition:start({ mapId = 61, fieldData = { transitionEnvironment = "outdoors" } }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "environment" },
  }, "east")
  Assert.equal(transition.profileId, 6)
  Assert.equal(metadataCalls, 1)
  Assert.isTrue(transition.locked)
end

function T.tests.field_transition_rejects_unsupported_environment_before_lock()
  local transition = FieldTransition.new({
    loader = {
      transitionEnvironment = function()
        return "outdoors"
      end,
    },
    prepare = function() end,
    commit = function() end,
  })

  local ok, err = pcall(function()
    transition:start({ mapId = 61, fieldData = { transitionEnvironment = "outdoors" } }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "environment" },
    }, "east")
  end)
  Assert.isFalse(ok)
  if type(err) ~= "table" then
    error("expected a structured transition profile error")
  end
  Assert.equal(err.code, "MAP_TRANSITION_PROFILE_UNSUPPORTED")
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
end

function T.tests.field_transition_uses_trigger_destination_facing()
  local receivedFacing
  local transition = FieldTransition.new({
    loader = {},
    fadeOutTicks = 1,
    fadeInTicks = 1,
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function(_, facing)
      receivedFacing = facing
    end,
    commit = function() end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
    destinationFacing = "west",
  }, "east")
  transition:updateFixed()
  transition:updateFixed()
  Assert.equal(receivedFacing, "west")
end

local function runTransition(options)
  local source = { mapId = 61 }
  local destination = { mapId = 60 }
  local transition = FieldTransition.new({
    loader = {},
    fadeOutTicks = 1,
    fadeInTicks = 1,
    resolveDestination = function()
      return {
        destinationMap = destination,
        destinationWarp = { x = 4, z = 14 },
        fieldX = 4,
        fieldZ = 13,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function() end,
    commit = function() end,
    doorAt = options.doorAt,
    playSound = options.playSound,
    player = options.player,
  })
  transition:start(
    source,
    { kind = "door", warp = { index = 0, x = 684, z = 393, destinationMapId = 60, destinationWarpId = 0 } },
    "north"
  )
  for _ = 1, 40 do
    if transition.phase == "idle" then
      break
    end
    transition:updateFixed()
  end
  Assert.equal(transition.phase, "idle", "the pure transition fixture must complete")
end

local function instantDoor(soundType)
  return {
    soundType = soundType,
    open = function() end,
    close = function() end,
    isFinished = function()
      return true
    end,
  }
end

function T.tests.door_sound_selector_emits_exact_open_and_close_sequences()
  local expected = {
    [1] = { "SEQ_SE_DP_DOOR_OPEN", "SEQ_SE_DP_DOOR_CLOSE2" },
    [2] = { "SEQ_SE_DP_DOOR10" },
    [3] = { "SEQ_SE_PL_DOOR_OPEN5" },
    [4] = { "SEQ_SE_GS_HIKIDO_OPEN", "SEQ_SE_GS_HIKIDO_CLOSE" },
  }
  for soundType = 1, 4 do
    local sounds = {}
    local door = instantDoor(soundType)
    runTransition({
      doorAt = function()
        return door
      end,
      playSound = function(sequence)
        sounds[#sounds + 1] = sequence
      end,
    })
    Assert.deepEqual(sounds, expected[soundType], "door sound selector " .. soundType)
  end
end

function T.tests.door_profile_steps_north_into_source_and_south_out_of_destination()
  local player = {
    motion = "idle",
    steps = {},
    scriptedStep = function(self, direction)
      self.steps[#self.steps + 1] = direction
      self.motion = "idle"
      return true
    end,
  }
  local door = instantDoor(1)
  runTransition({
    doorAt = function()
      return door
    end,
    player = player,
  })
  Assert.deepEqual(player.steps, { "north", "south" })
end

return T
