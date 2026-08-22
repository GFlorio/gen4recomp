-- Pure transition-profile contracts. These fixtures isolate source-selected
-- door audio and the asymmetric HGSS door movement from ROM loading.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.engine.src.FieldTransition")
local FieldTransitionProfile = require("libs.engine.src.FieldTransitionProfile")

local T = { tests = {} }

function T.transition_profiles_preserve_source_semantics()
  local outdoor = { scene = { type = "outdoor" } }
  local indoor = { scene = { type = "indoor" } }
  Assert.equal(FieldTransitionProfile.select("door", outdoor, indoor), 1)
  Assert.equal(FieldTransitionProfile.select("stairs", outdoor, outdoor), 3)
  Assert.equal(FieldTransitionProfile.select("directional", indoor, indoor), 6)
  Assert.equal(FieldTransitionProfile.select("directional", outdoor, indoor), 0)
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
