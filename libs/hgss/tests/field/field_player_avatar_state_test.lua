-- The player avatar transition owner keeps one durable mode, one displayed
-- visual, and the pending semantic transition set. Ordered application,
-- durable/temporary separation, cycling sound intent, and the surfing
-- presentation phase all live here; audio, graphics, and script scheduling
-- stay with the collaborators that consume the returned result.

local Assert = require("tests.support.Assert")
local AvatarState = require("libs.hgss.src.field.FieldPlayerAvatarState")

local T = {}

local VISUAL_STATES = {
  "walking",
  "cycling",
  "surfing",
  "watering",
  "fishing",
  "poketch",
  "saving",
  "heal",
  "ladder",
  "rocket",
  "rocket_heal",
  "pokeathlon",
  "apricorn_shake",
  "rocket_saving",
}

local function capability()
  local states = {}
  for index, name in ipairs(VISUAL_STATES) do
    states[name] = 1000 + index
  end
  return { id = "hero", gender = 0, states = states }
end

local function surfPresentation()
  return {
    initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
    playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
    yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
  }
end

local function walkingState(initialState)
  return AvatarState.new({
    capability = capability(),
    surfPresentation = surfPresentation(),
    initialState = initialState,
  })
end

local function spriteOf(name)
  for index, state in ipairs(VISUAL_STATES) do
    if state == name then
      return 1000 + index
    end
  end
  error("unknown visual state " .. tostring(name))
end

function T.boots_walking_stable_with_no_pending()
  local state = walkingState()
  Assert.equal(state:currentSpriteId(), spriteOf("walking"))
  Assert.isTrue(state:isStableForSave(), "a fresh boot must be save-stable")
  Assert.deepEqual(state:capture(), { state = "walking" })
  local presentation = state:presentationState()
  Assert.deepEqual(presentation.playerOffset, { x = 0, y = 0, z = 0 })
  Assert.isFalse(presentation.surf.active)
  local result = state:applyTransitions()
  Assert.equal(result.spriteId, spriteOf("walking"))
  Assert.isFalse(result.spriteChanged)
  Assert.deepEqual(result.sounds, {})
end

function T.scrambled_batch_applies_in_source_order()
  local state = walkingState()
  state:queueTransition("rocket_heal")
  state:queueTransition("heal")
  state:queueTransition("surfing")
  state:queueTransition("cycling")
  state:queueTransition("rocket")
  local result = state:applyTransitions()
  Assert.equal(result.spriteId, spriteOf("rocket_heal"), "the last source-ordered visual wins")
  Assert.isTrue(result.spriteChanged)
  Assert.deepEqual(result.sounds, { "SEQ_SE_DP_JITENSYA" }, "the earlier cycling side effect survives")
  Assert.deepEqual(state:capture(), { state = "rocket" }, "the later persistent transition wins durable state")
  Assert.equal(state:currentSpriteId(), spriteOf("rocket_heal"))
  Assert.isFalse(state:presentationState().surf.active, "rocket tears down surf")
  Assert.isFalse(state:isStableForSave(), "a temporary visual over durable state is unstable")
  state:queueTransition("heal")
  local followup = state:applyTransitions()
  Assert.equal(followup.spriteId, spriteOf("heal"))
  Assert.deepEqual(state:capture(), { state = "rocket" }, "the pending set was cleared by the first apply")
end

function T.cycling_then_heal_keeps_durable_cycling_with_one_sound()
  local state = walkingState()
  state:queueTransition("heal")
  state:queueTransition("cycling")
  local result = state:applyTransitions()
  Assert.equal(result.spriteId, spriteOf("heal"))
  Assert.deepEqual(result.sounds, { "SEQ_SE_DP_JITENSYA" })
  Assert.deepEqual(state:capture(), { state = "cycling" })
  Assert.isFalse(state:presentationState().surf.active)
  Assert.isFalse(state:isStableForSave())
end

function T.surfing_then_heal_keeps_surf_active_under_heal_visual()
  local state = walkingState()
  state:queueTransition("surfing")
  state:queueTransition("heal")
  local result = state:applyTransitions()
  Assert.equal(result.spriteId, spriteOf("heal"))
  Assert.deepEqual(state:capture(), { state = "surfing" })
  Assert.isTrue(state:presentationState().surf.active, "a temporary visual must not tear down surf")
  Assert.isFalse(state:isStableForSave())
end

function T.cycling_then_surfing_ends_surfing_but_keeps_the_bike_sound()
  local state = walkingState()
  state:queueTransition("surfing")
  state:queueTransition("cycling")
  local result = state:applyTransitions()
  Assert.equal(result.spriteId, spriteOf("surfing"))
  Assert.deepEqual(result.sounds, { "SEQ_SE_DP_JITENSYA" })
  Assert.deepEqual(state:capture(), { state = "surfing" })
  Assert.isTrue(state:presentationState().surf.active)
  Assert.isTrue(state:isStableForSave())
end

function T.surfing_then_rocket_tears_down_surf()
  local state = walkingState()
  state:queueTransition("surfing")
  state:applyTransitions()
  Assert.isTrue(state:presentationState().surf.active)
  state:queueTransition("rocket")
  local result = state:applyTransitions()
  Assert.equal(result.spriteId, spriteOf("rocket"))
  Assert.deepEqual(state:capture(), { state = "rocket" })
  Assert.isFalse(state:presentationState().surf.active)
  Assert.deepEqual(state:presentationState().playerOffset, { x = 0, y = 0, z = 0 })
end

function T.rocket_then_rocket_heal_keeps_durable_rocket()
  local state = walkingState()
  state:queueTransition("rocket_heal")
  state:queueTransition("rocket")
  local result = state:applyTransitions()
  Assert.equal(result.spriteId, spriteOf("rocket_heal"))
  Assert.deepEqual(state:capture(), { state = "rocket" })
  Assert.isFalse(state:isStableForSave())
end

function T.queue_order_never_beats_source_order()
  local first = walkingState()
  first:queueTransition("rocket")
  first:queueTransition("cycling")
  local firstResult = first:applyTransitions()
  local second = walkingState()
  second:queueTransition("cycling")
  second:queueTransition("rocket")
  local secondResult = second:applyTransitions()
  Assert.equal(firstResult.spriteId, secondResult.spriteId)
  Assert.equal(firstResult.spriteId, spriteOf("rocket"), "the later source-ordered transition wins either way")
  Assert.deepEqual(first:capture(), { state = "rocket" })
end

function T.repeated_queue_collapses_to_one_sound()
  local state = walkingState()
  state:queueTransition("cycling")
  state:queueTransition("cycling")
  state:queueTransition("cycling")
  local result = state:applyTransitions()
  Assert.deepEqual(result.sounds, { "SEQ_SE_DP_JITENSYA" }, "set-union queueing plays the sound once")
  Assert.deepEqual(state:capture(), { state = "cycling" })
end

function T.empty_apply_is_idempotent()
  local state = walkingState()
  state:queueTransition("cycling")
  state:applyTransitions()
  local first = state:applyTransitions()
  Assert.equal(first.spriteId, spriteOf("cycling"))
  Assert.isFalse(first.spriteChanged)
  Assert.deepEqual(first.sounds, {})
  Assert.isTrue(state:isStableForSave())
end

function T.unknown_transition_raises_and_keeps_pending()
  local state = walkingState()
  state:queueTransition("cycling")
  local err = Assert.throws(function()
    state:queueTransition("motorbike")
  end)
  Assert.notNil(err)
  local result = state:applyTransitions()
  Assert.equal(result.spriteId, spriteOf("cycling"), "the failed queue must not consume earlier work")
  Assert.deepEqual(result.sounds, { "SEQ_SE_DP_JITENSYA" })
end

function T.reapplying_surfing_restarts_the_creation_phase()
  local state = walkingState()
  state:queueTransition("surfing")
  state:applyTransitions()
  for _ = 1, 3 do
    state:updateFixed()
  end
  local drifted = state:presentationState().playerOffset.y
  Assert.isTrue(drifted ~= 4 / 16, "the oscillator must have moved the offset")
  state:queueTransition("surfing")
  state:applyTransitions()
  Assert.deepEqual(
    state:presentationState().playerOffset,
    { x = 0, y = 4 / 16, z = 4 / 16 },
    "recreating surf restarts the source creation phase"
  )
end

function T.temporary_visual_blocks_stable_save_until_restored()
  local state = walkingState()
  state:queueTransition("cycling")
  state:applyTransitions()
  Assert.isTrue(state:isStableForSave())
  state:queueTransition("heal")
  state:applyTransitions()
  Assert.isFalse(state:isStableForSave(), "a temporary visual over durable cycling must defer capture")
  state:queueTransition("cycling")
  state:applyTransitions()
  Assert.isTrue(state:isStableForSave())
  Assert.deepEqual(state:capture(), { state = "cycling" })
end

function T.pending_transition_blocks_stable_save()
  local state = walkingState()
  state:queueTransition("cycling")
  Assert.isFalse(state:isStableForSave(), "queued but unapplied work must defer capture")
end

function T.surfing_boots_active_at_the_creation_phase()
  local state = walkingState("surfing")
  Assert.equal(state:currentSpriteId(), spriteOf("surfing"))
  Assert.deepEqual(state:capture(), { state = "surfing" })
  Assert.isTrue(state:isStableForSave())
  local presentation = state:presentationState()
  Assert.isTrue(presentation.surf.active)
  Assert.deepEqual(presentation.playerOffset, { x = 0, y = 4 / 16, z = 4 / 16 })
end

function T.constructor_rejects_incomplete_capability_and_bad_initial_state()
  local incomplete = capability()
  incomplete.states.heal = nil
  Assert.throws(function()
    AvatarState.new({ capability = incomplete, surfPresentation = surfPresentation() })
  end)
  Assert.throws(function()
    AvatarState.new({
      capability = capability(),
      surfPresentation = surfPresentation(),
      initialState = "heal",
    })
  end)
  Assert.throws(function()
    AvatarState.new({ capability = capability(), surfPresentation = surfPresentation(), initialState = "nope" })
  end)
end

function T.surfing_starts_at_the_creation_offset_before_the_first_tick()
  local state = walkingState()
  state:queueTransition("surfing")
  state:applyTransitions()
  local presentation = state:presentationState()
  Assert.isTrue(presentation.surf.active)
  Assert.deepEqual(presentation.playerOffset, { x = 0, y = 4 / 16, z = 4 / 16 })
  Assert.near(presentation.surf.attachmentOffsetY, 0, 1e-12)
end

function T.surf_oscillator_bounces_at_both_bounds()
  local state = walkingState()
  state:queueTransition("surfing")
  state:applyTransitions()
  state:updateFixed()
  local first = state:presentationState()
  Assert.near(first.playerOffset.y, 0.328125, 1e-12)
  Assert.near(first.playerOffset.x, 0, 1e-12)
  Assert.near(first.playerOffset.z, 0.25, 1e-12)
  Assert.near(first.surf.attachmentOffsetY, 0.015625, 1e-12)
  for _ = 2, 12 do
    state:updateFixed()
  end
  local peak = state:presentationState()
  Assert.near(peak.playerOffset.y, 0.5, 1e-12, "twelve steps reach the upper bound")
  Assert.near(peak.surf.attachmentOffsetY, 0.1875, 1e-12)
  state:updateFixed()
  local falling = state:presentationState()
  Assert.near(falling.playerOffset.y, 0.484375, 1e-12, "the upper bound reverses the delta")
  Assert.near(falling.surf.attachmentOffsetY, 0.171875, 1e-12)
  for _ = 14, 24 do
    state:updateFixed()
  end
  local trough = state:presentationState()
  Assert.near(trough.playerOffset.y, 0.3125, 1e-12, "twelve falling steps reach the lower bound")
  Assert.near(trough.surf.attachmentOffsetY, 0, 1e-12)
  state:updateFixed()
  local rising = state:presentationState()
  Assert.near(rising.playerOffset.y, 0.328125, 1e-12, "the lower bound reverses the delta")
end

function T.heal_preserves_surf_phase_then_walking_clears_it()
  local state = walkingState()
  state:queueTransition("surfing")
  state:applyTransitions()
  state:updateFixed()
  state:updateFixed()
  local before = state:presentationState()
  state:queueTransition("heal")
  local healResult = state:applyTransitions()
  Assert.equal(healResult.spriteId, spriteOf("heal"))
  local during = state:presentationState()
  Assert.isTrue(during.surf.active)
  Assert.near(during.playerOffset.y, before.playerOffset.y, 1e-12, "a temporary visual keeps the surf phase")
  Assert.near(during.surf.attachmentOffsetY, before.surf.attachmentOffsetY, 1e-12)
  state:queueTransition("walking")
  local walkResult = state:applyTransitions()
  Assert.equal(walkResult.spriteId, spriteOf("walking"))
  local after = state:presentationState()
  Assert.isFalse(after.surf.active)
  Assert.deepEqual(after.playerOffset, { x = 0, y = 0, z = 0 })
  Assert.deepEqual(state:capture(), { state = "walking" })
end

function T.cycling_reports_the_bike_sound_symbol()
  local state = walkingState()
  state:queueTransition("cycling")
  local result = state:applyTransitions()
  Assert.deepEqual(result.sounds, { "SEQ_SE_DP_JITENSYA" })
  Assert.deepEqual(state:capture(), { state = "cycling" })
end

function T.snapshots_carry_no_logical_coordinates()
  local state = walkingState()
  state:queueTransition("surfing")
  state:applyTransitions()
  state:updateFixed()
  local snapshot = state:status()
  Assert.isNil(snapshot.worldX)
  Assert.isNil(snapshot.worldY)
  Assert.isNil(snapshot.worldZ)
  Assert.isNil(snapshot.fieldX)
  Assert.isNil(snapshot.fieldZ)
  local presentation = state:presentationState()
  ---@diagnostic disable-next-line: undefined-field -- absence of logical coordinates is the asserted contract
  Assert.isNil(presentation.worldX)
  ---@diagnostic disable-next-line: undefined-field -- absence of logical coordinates is the asserted contract
  Assert.isNil(presentation.fieldX)
end

return { tests = T }
