-- Pure transition-profile contracts. These fixtures isolate source-selected
-- door audio and the asymmetric HGSS door movement from ROM loading.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.engine.src.FieldTransition")
local FieldTransitionProfile = require("libs.engine.src.FieldTransitionProfile")

local T = { tests = {} }

local function advanceTo(transition, phase, maxTicks)
  for _ = 1, maxTicks do
    if transition.phase == phase then
      return
    end
    transition:updateFixed()
  end
  Assert.equal(transition.phase, phase)
end

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

function T.tests.all_fixed_profiles_are_explicit_and_panel_has_no_numeric_profile()
  for profile = 0, 8 do
    Assert.equal(FieldTransitionProfile.fixed(profile).profile, profile)
  end
  Assert.throws(function()
    FieldTransitionProfile.fixed(-1)
  end, "negative transition profiles are invalid")
  Assert.throws(function()
    FieldTransitionProfile.fixed(9)
  end, "unknown transition profiles are invalid")

  local transition = FieldTransition.new({
    loader = {},
    prepare = function() end,
    commit = function() end,
  })
  transition:start(
    { mapId = 61 },
    { warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 }, transition = { mode = "panel" } },
    "north"
  )
  Assert.isNil(transition.profileId)
  Assert.equal(transition.transitionMode, FieldTransitionProfile.MODE_PANEL)
end

function T.tests.ordinary_profiles_share_source_exit_audio_and_fade()
  local observations = {}
  for _, profile in ipairs({ FieldTransitionProfile.ORDINARY, FieldTransitionProfile.ORDINARY_INDOOR }) do
    local sounds = {}
    local transition = FieldTransition.new({
      loader = {},
      prepare = function() end,
      commit = function() end,
      playSound = function(sound)
        sounds[#sounds + 1] = sound
      end,
    })
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "north")
    observations[#observations + 1] = {
      profile = profile,
      sounds = sounds,
      fade = transition.fade:status(),
    }
  end

  Assert.deepEqual(observations[1].sounds, { "SEQ_SE_DP_KAIDAN2" }, "profile 0 source exit audio")
  Assert.deepEqual(observations[2].sounds, observations[1].sounds, "profile 6 shares profile 0 source exit audio")
  Assert.equal(observations[2].fade.coefficient, observations[1].fade.coefficient)
end

function T.tests.transition_motion_profiles_require_the_player_motion_contract()
  local transition = FieldTransition.new({
    loader = {},
    prepare = function() end,
    commit = function() end,
  })
  Assert.throws(function()
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
    }, "south")
  end, "transition movement profiles require beginTransitionMotion")
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
  local player = {
    motion = "idle",
    beginTransitionMotion = function(self, _, _, facing)
      self.motion = "idle"
      self.facing = facing
      return true
    end,
    updateFixed = function() end,
  }
  local transition = FieldTransition.new({
    loader = {},
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function(_, facing)
      receivedFacing = facing
    end,
    commit = function() end,
    player = player,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
    destinationFacing = "west",
  }, "east")
  advanceTo(transition, "swap_map", 4)
  Assert.equal(receivedFacing, "west")
end

local function runTransition(options)
  local source = { mapId = 61 }
  local destination = { mapId = 60 }
  local transition = FieldTransition.new({
    loader = {},
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
  local open = {
    [1] = "SEQ_SE_DP_DOOR_OPEN",
    [2] = "SEQ_SE_DP_DOOR10",
    [3] = "SEQ_SE_PL_DOOR_OPEN5",
    [4] = "SEQ_SE_GS_HIKIDO_OPEN",
  }
  local close = {
    [1] = "SEQ_SE_DP_DOOR_CLOSE2",
    [2] = nil,
    [3] = nil,
    [4] = "SEQ_SE_GS_HIKIDO_CLOSE",
  }
  return {
    soundType = soundType,
    open = function()
      return open[soundType]
    end,
    close = function()
      return close[soundType]
    end,
    isFinished = function()
      return true
    end,
  }
end

function T.tests.door_audio_comes_only_from_door_operations()
  local sounds = {}
  local door = {
    soundType = 1,
    open = function()
      return "SEQ_FROM_OPEN"
    end,
    close = function()
      return nil
    end,
    isFinished = function()
      return true
    end,
  }
  runTransition({
    doorAt = function()
      return door
    end,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
  })
  Assert.deepEqual(sounds, { "SEQ_FROM_OPEN" })
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

function T.tests.door_profile_steps_north_into_source_and_north_out_of_destination()
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
  Assert.deepEqual(player.steps, { "north", "north" })
end

function T.tests.nonordinary_profiles_dispatch_exit_enter_and_camera_families()
  local events = {}
  local player = {
    motion = "idle",
    facing = "south",
    beginTransitionMotion = function(self, profile, phase, facing)
      events[#events + 1] = { profile = profile, phase = "movement", family = phase .. ":" .. facing }
      self.motion = "transition"
      self.transitionTicks = 0
      self.facing = facing
      return true
    end,
    updateFixed = function(self)
      self.transitionTicks = self.transitionTicks + 1
      if self.transitionTicks == 1 then
        self.motion = "idle"
      end
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = {},
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    player = player,
    onProfile = function(profile, phase, family)
      events[#events + 1] = { profile = profile, phase = phase, family = family }
    end,
    cameraAdjust = function(profile, adjustment)
      events[#events + 1] = { profile = profile, phase = "camera", family = adjustment }
    end,
  })

  for _, profile in ipairs({ 2, 4, 5, 7, 8 }) do
    events = {}
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "south")
    for _ = 1, 20 do
      if transition.phase == "idle" then
        break
      end
      transition:updateFixed()
    end
    Assert.equal(transition.phase, "idle", "profile " .. profile .. " completes")
    Assert.equal(events[1].profile, profile)
    Assert.equal(events[1].phase, "exit")
    Assert.equal(events[1].family, FieldTransitionProfile.ROUTINE_FAMILIES[profile].exit)
    local enter
    for index, event in ipairs(events) do
      if event.phase == "enter" then
        enter = event
        break
      end
    end
    Assert.notNil(enter, "profile " .. profile .. " must dispatch its enter routine")
    Assert.equal(enter.profile, profile)
    Assert.equal(enter.family, FieldTransitionProfile.ROUTINE_FAMILIES[profile].enter)
    local camera = FieldTransitionProfile.ROUTINE_FAMILIES[profile].adjustment
    if camera then
      local cameraEvent
      for _, event in ipairs(events) do
        if event.phase == "camera" then
          cameraEvent = event
          break
        end
      end
      Assert.notNil(cameraEvent, "profile " .. profile .. " must adjust the camera")
      Assert.equal(cameraEvent.family, camera)
    else
      for _, event in ipairs(events) do
        Assert.isFalse(event.phase == "camera", "profile " .. profile .. " must not adjust the camera")
      end
    end
  end
end

function T.tests.panel_lifecycle_notifies_each_side_once_without_profile_dispatch()
  local panels = {}
  local profiles = {}
  local transition = FieldTransition.new({
    loader = {},
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    onPanel = function(phase)
      panels[#panels + 1] = phase
    end,
    onProfile = function()
      profiles[#profiles + 1] = true
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "panel" },
  }, "south")
  for _ = 1, 10 do
    if transition.phase == "idle" then
      break
    end
    transition:updateFixed()
  end
  Assert.deepEqual(panels, { "exit", "enter" })
  Assert.deepEqual(profiles, {})
end

function T.tests.profile_hook_failure_aborts_before_commit_but_after_commit_propagates()
  local commits = 0
  local before = FieldTransition.new({
    loader = {},
    onProfile = function(_, phase)
      if phase == "exit" then
        error("exit failed", 0)
      end
    end,
    prepare = function() end,
    commit = function()
      commits = commits + 1
    end,
  })
  local ok, err = pcall(function()
    before:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = 4 },
    }, "south")
  end)
  Assert.isFalse(ok)
  Assert.equal(tostring(err), "exit failed")
  Assert.equal(before.phase, "idle")
  Assert.isFalse(before.locked)
  Assert.isNil(before.sourceMap)
  Assert.equal(tostring(before.error), "exit failed")
  Assert.equal(commits, 0)

  local after = FieldTransition.new({
    loader = {},
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    onProfile = function(_, phase)
      if phase == "enter" then
        error("enter failed", 0)
      end
    end,
  })
  after:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = 4 },
  }, "south")
  advanceTo(after, "swap_map", 4)
  local ok, err = pcall(after.updateFixed, after)
  Assert.isFalse(ok)
  Assert.equal(tostring(err), "enter failed")
  Assert.equal(after.phase, "swap_map")
end

return T
