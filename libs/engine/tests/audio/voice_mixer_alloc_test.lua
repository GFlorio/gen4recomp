-- VoiceMixer allocation, per-note control, LFO and sweep contract: the
-- ARM7 NitroSDK per-voice NNS channel state (tmp/refs/pokediamond/arm7/
-- lib/src/SND_exChannel.c, SND_util.c, SND_bank.c, SND_seq.c) and GBATEK
-- ("DS Sound" chapter).
--   * Allocation is SND_AllocExChannel: the fixed order
--     {4,5,6,7,2,0,3,1,8,9,10,11,14,12,15,13} inside (generator range AND
--     channelMask); the victim is the lowest effective priority
--     (channelPriority + trackPriority, one sum) and among equals the
--     quieter last-synced volume register; an incoming note below the
--     victim's priority is rejected; a stolen channel revokes the previous
--     voice handle so a later noteOff cannot kill the replacement.
--   * noteOn returns {channel, generation} (generation persists per channel
--     and increments on every allocation, so a naturally freed channel never
--     reuses the old generation) or nil; noteOff/updateVoice/isVoiceAlive on
--     a stale handle are harmless.
--   * TrackUpdateChannel per-main control values (track volume, expression,
--     sequence volume, fader, pan offset) reach the channel at the next
--     control step -- 192 Hz, i.e. one step per 250 output frames at 48 kHz
--     (SND_TIMER_RATE 240 at the 192 Hz sound interval, the cadence the
--     sequence player already derives its tick clock from). The noteOn
--     noteOn initializes the channel; subsequent steps fire every
--     CONTROL_PERIOD frames on the mixer's absolute frame count.
--   * LFO (SND_UpdateLfo/SND_GetLfoValue/SND_SinIdx) and sweep
--     (ExChannelSweepUpdate) state machines run per control step and feed
--     the pitch/volume/pan calculations.
--
-- The voice/spec shapes follow the agreed contracts: voice = {generator,
-- originalKey, envelope, pan}; sample descriptor = {schema, key, frames,
-- baseTimer, loopEnabled, loop}. Every expected value below is a
-- known vector transcribed from the SDK sources or the NDS ARM7 BIOS tables
-- (getpitchtbl/getvoltbl hardware dumps); the tests never reimplement the
-- SDK algorithms.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")

local T = {}

local SAMPLE_RATE = 48000
-- One NNS control step per 250 output frames at 48 kHz (192 Hz sound
-- interval).
local CONTROL = 250

-- Distinct small-amplitude waves so voice sums never clip and every voice is
-- identifiable in the mix.
local WAVE_A = { 100, 200, 300, 400, 500, 600, 700, 800 }
local WAVE16 = {}
for i = 1, 16 do
  WAVE16[i] = i * 100
end
-- A constant wave for the stale-handle pins: the full register gain 1 makes
-- every frame's expected sample the constant itself.
local CONST_4096 = { 4096, 4096, 4096, 4096, 4096, 4096, 4096, 4096 }

local function newMixer(rate)
  local mixer = VoiceMixer.new({ sampleRate = rate or SAMPLE_RATE })
  local noteOn = mixer.noteOn
  ---@diagnostic disable-next-line: duplicate-set-field
  rawset(mixer, "noteOn", function(self, noteSpec)
    local handle = noteOn(self, noteSpec)
    if handle ~= nil then
      self:controlStep()
    end
    return handle
  end)
  return mixer
end

-- Renders `frames` through the external-drive contract: one 250-frame span
-- per renderInto call, with one explicit controlStep at each interval
-- boundary (the scheduler's 192 Hz cadence at 48 kHz). The mixer never
-- control-steps inside renderInto.
local function drive(mixer, out, frames)
  local remaining = frames
  while remaining > 0 do
    local span = math.min(remaining, CONTROL)
    mixer:renderInto(out, span)
    remaining = remaining - span
    if remaining > 0 then
      mixer:controlStep()
    end
  end
end

-- The frozen voice shape plus the per-note inputs: generator, originalKey,
-- envelope, pan, key, velocity, trackVolume/expression/sequenceVolume,
-- channelMask, trackPriority, channelPriority, and the optional channel-side
-- controls (userPitch 0, trackPanOffset 0, panRange 127, fader 0,
-- sweepPitch 0, sweepLength 0, autoSweep true, lfo {target 0=pitch/1=volume/
-- 2=pan, depth 0, range 1, speed 16, delay 0}). Sample voices carry no
-- source sample rate: playback derives from the DS sound clock and the
-- calculated timer.
local function spec(overrides)
  local s = {
    generator = { kind = "sample", sample = AudioFixture.key(1) },
    pcm = WAVE_A,
    baseTimer = 8006,
    loopEnabled = true,
    loop = { startFrame = 0, endFrame = 8 },
    key = 60,
    originalKey = 60,
    velocity = 127,
    trackVolume = 127,
    expression = 127,
    sequenceVolume = 127,
    envelope = { attack = 127, decay = 127, sustain = 127, release = 127 },
    pan = 64,
    channelMask = 0xFFFF,
    trackPriority = 64,
    channelPriority = 64,
  }
  for key, value in pairs(overrides or {}) do
    s[key] = value
  end
  return s
end

local function leftAt(pcm, frame)
  return pcm[frame * 2 - 1]
end

local function rightAt(pcm, frame)
  return pcm[frame * 2]
end

-- SND_AllocExChannel: the fixed channel order {4,5,6,7,2,0,3,1,8,9,10,11,
-- 14,12,15,13} inside (generator range AND channelMask); noteOn returns a
-- {channel, generation} handle with generation 0-based and incremented per
-- channel reuse.
function T.allocation_follows_the_sdk_channel_order_and_generator_masks()
  local mixer = newMixer()
  local order = { 4, 5, 6, 7, 2, 0, 3, 1, 8, 9, 10, 11, 14, 12, 15, 13 }
  for i = 1, 16 do
    local handle = mixer:noteOn(spec())
    Assert.notNil(handle, "sixteen sample voices fit")
    Assert.deepEqual(
      handle,
      { channel = order[i], generation = 0 },
      "sample voice " .. i .. " takes the SDK order channel"
    )
  end
  local square = newMixer()
  local squareChannels = {}
  for i = 1, 6 do
    squareChannels[i] = square:noteOn(spec({ generator = { kind = "square", duty = 4 }, channelMask = 0x3F00 }))
  end
  for i = 1, 6 do
    Assert.equal(squareChannels[i].channel, 7 + i, "square voices take channels 8..13 in order")
  end
  local noise = newMixer()
  Assert.equal(
    noise:noteOn(spec({ generator = { kind = "noise" }, channelMask = 0xC000 })).channel,
    14,
    "the first noise voice takes channel 14"
  )
  Assert.equal(
    noise:noteOn(spec({ generator = { kind = "noise" }, channelMask = 0xC000 })).channel,
    15,
    "the second noise voice takes channel 15"
  )
  local restricted = newMixer()
  Assert.isNil(
    restricted:noteOn(spec({ generator = { kind = "square", duty = 4 }, channelMask = 0xC000 })),
    "square has no channel inside a noise-only mask"
  )
  Assert.isNil(
    restricted:noteOn(spec({ generator = { kind = "noise" }, channelMask = 0x3F00 })),
    "noise has no channel inside a square-only mask"
  )
  Assert.isNil(
    restricted:noteOn(spec({ generator = { kind = "square", duty = 4 }, channelMask = 0x00FF })),
    "square has no channel inside mask 0-7"
  )
  local masked = newMixer()
  Assert.equal(
    masked:noteOn(spec({ channelMask = 0x0003 })).channel,
    0,
    "the sample voice takes the first SDK-order channel in the mask"
  )
  Assert.equal(
    masked:noteOn(spec({ channelMask = 0x0003 })).channel,
    1,
    "the second sample voice takes the next SDK-order channel"
  )
end

-- Effective priority is the single sum channelPriority + trackPriority
-- (TrackPlayNote); the victim is the occupied channel with the lowest sum
-- (not a separate SeqPlayer priority), an incoming note below the victim's
-- priority is rejected (SND_AllocExChannel), and an equal priority passes.
-- The contested notes carry a mask covering only the already-occupied
-- channels so the victim selection is observable (a free channel is always
-- the lowest-priority candidate and would win instead).
function T.allocation_uses_the_priority_sum_and_rejects_weak_notes()
  local mixer = newMixer()
  local v1 = mixer:noteOn(spec({ channelPriority = 10, trackPriority = 100 }))
  local v2 = mixer:noteOn(spec({ channelPriority = 50, trackPriority = 40 }))
  local v3 = mixer:noteOn(spec({ channelPriority = 60, trackPriority = 60 }))
  Assert.deepEqual(v1, { channel = 4, generation = 0 }, "the first voice is at channel 4")
  Assert.deepEqual(v2, { channel = 5, generation = 0 }, "the second voice is at channel 5")
  Assert.deepEqual(v3, { channel = 6, generation = 0 }, "the third voice is at channel 6")
  local stolen = mixer:noteOn(spec({ channelPriority = 20, trackPriority = 80, channelMask = 0x0030 }))
  Assert.deepEqual(
    stolen,
    { channel = 5, generation = 1 },
    "priority 100 steals the lowest sum 90 voice on channel 5, not channel 4"
  )
  Assert.isNil(
    mixer:noteOn(spec({ channelPriority = 5, trackPriority = 5, channelMask = 0x0030 })),
    "priority 10 is below the occupied channel's priority and is rejected"
  )
  local equal = mixer:noteOn(spec({ channelPriority = 20, trackPriority = 80, channelMask = 0x0030 }))
  Assert.deepEqual(equal, { channel = 5, generation = 2 }, "priority 100 equals the victim's priority and steals")
end

function T.released_tails_are_immediately_stealable_at_priority_one()
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local old = mixer:noteOn(spec({
    channelMask = 0x0010,
    channelPriority = 100,
    trackPriority = 100,
  })) --[[@as { channel: integer, generation: integer }]]
  Assert.notNil(old, "the high-priority voice is allocated on channel 4")

  mixer:noteOff(old)
  local replacement = mixer:noteOn(spec({
    channelMask = 0x0010,
    channelPriority = 0,
    trackPriority = 2,
  })) --[[@as { channel: integer, generation: integer }]]
  Assert.deepEqual(
    replacement,
    { channel = 4, generation = old.generation + 1 },
    "a released tail is demoted before the next allocation"
  )
  mixer:noteOff(old)
  Assert.isTrue(mixer:isVoiceAlive(replacement), "a stale released handle cannot affect its replacement")
end

function T.admission_uses_full_priority_and_stores_the_low_u8_byte()
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local first = mixer:noteOn(spec({
    channelMask = 0x0010,
    channelPriority = 200,
    trackPriority = 100,
  })) --[[@as { channel: integer, generation: integer }]]
  Assert.notNil(first, "the full incoming priority admits the first voice")

  local second = mixer:noteOn(spec({
    channelMask = 0x0010,
    channelPriority = 50,
    trackPriority = 0,
  }))
  Assert.deepEqual(
    second,
    { channel = 4, generation = first.generation + 1 },
    "priority 50 steals the accepted priority-44 state"
  )
end

function T.occupied_zero_volume_channels_join_free_candidate_ties()
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local first = mixer:noteOn(spec({
    channelMask = 0x0010,
    velocity = 0,
    channelPriority = 0,
    trackPriority = 0,
  }))
  Assert.deepEqual(first, { channel = 4, generation = 0 })

  local replacement = mixer:noteOn(spec({
    channelMask = 0x0030,
    velocity = 0,
    channelPriority = 0,
    trackPriority = 0,
  }))
  Assert.deepEqual(
    replacement,
    { channel = 4, generation = 1 },
    "the occupied zero-volume channel wins the exact tie by allocation order"
  )
end

-- Among equal priorities the SDK steals the quieter channel: the victim
-- comparison uses the last-synced volume register
-- (ExChannelVolumeCmp: mantissa<<4 shifted by sSampleDataShiftTable), so a
-- velocity-64 voice (register 0x141 -> 520) loses to a velocity-127 voice
-- (register 0x7F -> 2032); a true tie takes the first channel in the
-- allocation order. The contested notes carry a mask covering only the
-- occupied channels so the victim comparison is observable.
function T.equal_priority_steals_the_quieter_channel()
  local mixer = newMixer()
  mixer:noteOn(spec({ velocity = 64 }))
  mixer:noteOn(spec({ velocity = 127 }))
  local stolen = mixer:noteOn(spec({ velocity = 127, channelMask = 0x0030 }))
  Assert.deepEqual(stolen, { channel = 4, generation = 1 }, "the quieter velocity-64 voice on channel 4 is the victim")
  local tie = newMixer()
  tie:noteOn(spec())
  tie:noteOn(spec())
  local victim = tie:noteOn(spec({ channelMask = 0x0030 }))
  Assert.deepEqual(
    victim,
    { channel = 4, generation = 1 },
    "a true tie takes the first channel in the allocation order"
  )
end

-- A stolen channel revokes the previous voice handle: the later noteOff or
-- updateVoice on the stale handle must not touch the replacement voice.
-- The replacement's mask covers only the old voice's channel so the steal
-- is observable (any other channel is free and would be allocated first).
function T.stolen_channels_revoke_the_previous_voice_handle()
  local mixer = newMixer()
  local pcmA = { 5120, 5120, 5120, 5120, 5120, 5120, 5120, 5120 }
  local pcmB = { 4096, 4096, 4096, 4096, 4096, 4096, 4096, 4096 }
  local old = mixer:noteOn(spec({ pcm = pcmA, pan = 0 })) --[[@as { channel: integer, generation: integer }]]
  local replacement = mixer:noteOn(spec({ pcm = pcmB, pan = 0, channelPriority = 80, channelMask = 0x0010 })) --[[@as { channel: integer, generation: integer }]]
  Assert.deepEqual(
    replacement,
    { channel = old.channel, generation = old.generation + 1 },
    "the high-priority note steals the old channel"
  )
  mixer:noteOff(old)
  mixer:noteOff({ channel = old.channel, generation = 99 })
  mixer:updateVoice(old, { trackVolume = 0 })
  local pcm = mixer:render(1)
  Assert.equal(leftAt(pcm, 1), 4096, "the stale noteOff and updateVoice leave the replacement voice untouched")
  mixer:noteOff(replacement)
  mixer:render(1)
end

-- TrackUpdateChannel per-main control values reach the channel at the next
-- control step: a track volume, expression, sequence volume, fader or pan
-- offset pushed after the first block changes the volume register or the
-- hardware pan register from the following 250-frame block on.
function T.track_control_updates_apply_at_the_next_control_step()
  local pcm = { 5120, 5120, 5120, 5120, 5120, 5120, 5120, 5120 }
  local function run(overrides, update)
    local mixer = newMixer()
    local handle = mixer:noteOn(spec(overrides)) --[[@as { channel: integer, generation: integer }]]
    local first = mixer:render(CONTROL)
    mixer:updateVoice(handle, update)
    -- The queued values apply at the next external control step (the
    -- scheduler's 250-frame interval boundary), not during rendering.
    mixer:controlStep()
    local second = mixer:render(CONTROL)
    return first, second
  end
  local first, second = run({ pcm = pcm, pan = 0 }, { trackVolume = 64 })
  Assert.equal(leftAt(first, CONTROL), 5120, "track volume 127 holds the full register")
  Assert.equal(leftAt(second, CONTROL), 1300, "track volume 64 reaches register 0x141 at the next control step")
  first, second = run({ pcm = pcm, pan = 0 }, { expression = 100 })
  Assert.equal(leftAt(second, CONTROL), 3160, "expression 100 reaches register 0x4F")
  first, second = run({ pcm = pcm, pan = 0 }, { sequenceVolume = 100 })
  Assert.equal(leftAt(second, CONTROL), 3160, "player volume 100 reaches register 0x4F")
  first, second = run({ pcm = pcm, pan = 0 }, { fader = -200 })
  Assert.equal(leftAt(second, CONTROL), 510, "the fader reaches register 0x233")
  first, second = run({ pcm = pcm, pan = 64 }, { trackPanOffset = 63 })
  Assert.equal(leftAt(second, CONTROL), 0, "the pan offset 63 moves the voice fully right")
  Assert.equal(rightAt(second, CONTROL), 5120, "the pan offset 63 moves the voice fully right")
  first, second = run({ pcm = pcm, pan = 64 }, { trackPanOffset = 32, panRange = 64 })
  Assert.equal(leftAt(second, CONTROL), 1920, "pan range 64 scales the offset to register 80")
  Assert.equal(rightAt(second, CONTROL), 3200, "pan range 64 scales the offset to register 80")
end

-- updateVoice retunes a live voice at the next control step: `key`
-- re-enters the note's pitch path (midiKey -> SND_CalcTimer -> timer/ratio)
-- without touching the envelope state or the release/attack status, so a
-- tied note keeps its attack progression. With base timer 512 the retune to
-- key 72 halves the timer (512 -> 256) and exactly doubles the read rate
-- from the boundary frame's own advance on; the attack-100 register pins
-- show the curve continued from step 3 instead of restarting.
function T.update_voice_retunes_the_key_at_the_next_control_step()
  local function run(overrides, firstLength, secondLength)
    local mixer = newMixer()
    local handle = mixer:noteOn(spec(overrides)) --[[@as { channel: integer, generation: integer }]]
    -- Drive the first block at the external 250-frame control cadence (the
    -- envelope/sweep advance at the boundaries), then apply the retune at
    -- the next control step so the second block reads the new pitch.
    local first = {}
    drive(mixer, first, firstLength)
    mixer:updateVoice(handle, { key = 72 })
    mixer:controlStep()
    local second = {}
    drive(mixer, second, secondLength)
    return first, second
  end
  local first, second = run({
    pcm = WAVE16,
    baseTimer = 512,
    pan = 0,
    loop = { startFrame = 0, endFrame = 16 },
  }, CONTROL, 300)
  Assert.equal(leftAt(first, CONTROL), 1000, "key 60 reads sample 10 through the first block (base timer 512)")
  Assert.equal(leftAt(second, 1), 1100, "the first frame after the retune continues the sample position")
  Assert.equal(leftAt(second, 3), 1400, "key 72 reads at twice the rate from the next frame")
  Assert.equal(leftAt(second, 5), 1600, "key 72 reads at twice the rate from the next frame")
  Assert.equal(leftAt(second, 7), 300, "key 72 reads at twice the rate from the next frame")

  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  first, second = run({
    pcm = pcm,
    pan = 0,
    loop = { startFrame = 0, endFrame = 8 },
    envelope = { attack = 100, decay = 127, sustain = 127, release = 127 },
  }, 500, 750)
  Assert.equal(leftAt(first, CONTROL), 13, "attack step 1 holds register 0x30D through the first block")
  Assert.equal(leftAt(first, CONTROL + 1), 96, "attack step 2 reaches register 0x360")
  Assert.equal(leftAt(second, CONTROL), 320, "the retune leaves the step-3 register untouched")
  Assert.equal(leftAt(second, CONTROL + 1), 664, "attack step 4 continues from the retuned voice")
  Assert.equal(leftAt(second, 750), 1040, "the attack continues toward the sustain register")
end

-- updateVoice userPitch reaches a live held voice at the next control step
-- through the same pitch path as the key retune: userPitch 768 is the
-- 12-semitone step that lands timer 256 from the 512 base timer (the timer
-- the key-72 retune uses), so the read rate doubles from the boundary
-- frame's own advance on while the sample position continues -- never
-- restarting the wave or the envelope. The boundary frame's own read hears
-- the new pitch; the frame before it still reads at the old rate.
function T.update_voice_user_pitch_changes_a_held_voice_at_the_next_control_step()
  local mixer = newMixer()
  local handle = mixer:noteOn(spec({
    pcm = WAVE16,
    baseTimer = 512,
    loop = { startFrame = 0, endFrame = 16 },
    pan = 0,
  })) --[[@as { channel: integer, generation: integer }]]
  local first = mixer:render(CONTROL)
  mixer:updateVoice(handle, { userPitch = 768 })
  -- The user pitch applies at the next external control step (the 250-frame
  -- boundary), so the second block reads the doubled rate from its start.
  mixer:controlStep()
  local second = mixer:render(300)
  Assert.equal(leftAt(first, CONTROL), 1000, "userPitch 0 holds the base-timer read rate (sample 10)")
  Assert.equal(leftAt(second, 1), 1100, "the first frame after the control step continues the sample position")
  Assert.equal(leftAt(second, 3), 1400, "userPitch 768 reads at the doubled rate from the next frame")
  Assert.equal(leftAt(second, 5), 1600, "userPitch 768 reads at the doubled rate from the next frame")
  Assert.equal(leftAt(second, 7), 300, "userPitch 768 reads at the doubled rate from the next frame")
end

-- updateVoice velocity reaches the volume dB sum at the next control step
-- like the other pending values: db[64] = -119 moves the register from 0x7F
-- to 0x141.
function T.update_voice_velocity_changes_the_volume_at_the_next_control_step()
  local pcm = { 5120, 5120, 5120, 5120, 5120, 5120, 5120, 5120 }
  local mixer = newMixer()
  local handle = mixer:noteOn(spec({ pcm = pcm, pan = 0, loop = { startFrame = 0, endFrame = 8 } })) --[[@as { channel: integer, generation: integer }]]
  local first = mixer:render(CONTROL)
  mixer:updateVoice(handle, { velocity = 64 })
  -- The velocity applies at the next external control step.
  mixer:controlStep()
  local second = mixer:render(CONTROL)
  Assert.equal(leftAt(first, CONTROL), 5120, "velocity 127 holds the full register through the first block")
  Assert.equal(leftAt(second, 1), 1300, "velocity 64 reaches register 0x141 from the first frame after the step")
  Assert.equal(leftAt(second, CONTROL), 1300, "velocity 64 holds register 0x141 through the second block")
end

-- The LFO state machine (SND_UpdateLfo counter, delay counter and
-- SND_SinIdx table) runs per control step; a pan-target LFO feeds the
-- hardware register through ExChannelLfoUpdate (sin*depth*range*64>>14).
-- With speed 16 the counter is 1024, 2048, 3072, 4096, 5120 at steps 4..8
-- (sinIdx 25, 49, 71, 90, 106 -> pan contributions 12, 24, 35, 44).
function T.lfo_pan_target_moves_the_hardware_register()
  local mixer = newMixer()
  mixer:noteOn(spec({
    pcm = { 6400, 6400, 6400, 6400, 6400, 6400, 6400, 6400 },
    lfo = { target = 2, depth = 127, range = 1, speed = 16, delay = 2 },
  }))
  local out = {}
  drive(mixer, out, 1750)
  local pins = {
    { 250, 3200, 3200, "delay 2 and the counter-0 step hold the center" },
    { 750, 3200, 3200, "the third step still contributes 0 (counter 0)" },
    { 1000, 2600, 3800, "step 4 reaches register 76" },
    { 1250, 2000, 4400, "step 5 reaches register 88" },
    { 1500, 1450, 4950, "step 6 reaches register 99" },
    { 1750, 1000, 5400, "step 7 reaches register 108" },
  }
  for _, pin in ipairs(pins) do
    Assert.equal(leftAt(out, pin[1]), pin[2], "LFO pan pin frame " .. pin[1])
    Assert.equal(rightAt(out, pin[1]), pin[3], "LFO pan pin frame " .. pin[1])
  end
end

-- Pitch- and volume-target LFOs feed their channel calculations: a
-- pitch-target LFO (contribution 12 at step 2 -> timer 506, 24 at step 3
-- -> timer 501 from a 512 base timer) advances the read faster than the
-- base-timer rate -- frame 451 reads sample 5 where the 0.68-sample/frame
-- baseline reads sample 3; a volume-target LFO (contributions 11, 22, 33,
-- 41) moves the dB sum from db[100] = -42 to registers 0x5A, 0x66, 0x73,
-- 0x7E.
function T.lfo_pitch_and_volume_targets_affect_their_calculations()
  local pitchMixer = newMixer()
  pitchMixer:noteOn(spec({
    pcm = WAVE16,
    baseTimer = 512,
    loop = { startFrame = 0, endFrame = 16 },
    lfo = { target = 0, depth = 127, range = 1, speed = 16, delay = 0 },
    pan = 0,
  }))
  local out = {}
  drive(pitchMixer, out, 560)
  Assert.equal(leftAt(out, 342), 1000, "the drift from step 2 leaves the read at sample 10 by frame 342")
  Assert.equal(leftAt(out, 450), 400, "the pitch-target LFO advances the read to sample 4 at frame 450")
  Assert.equal(leftAt(out, 451), 500, "the pitch-target LFO advances the read to sample 5 at frame 451")

  local volumeMixer = newMixer()
  volumeMixer:noteOn(spec({
    pcm = { 1280, 1280, 1280, 1280, 1280, 1280, 1280, 1280 },
    pan = 0,
    velocity = 100,
    lfo = { target = 1, depth = 127, range = 1, speed = 16, delay = 0 },
  }))
  local vout = {}
  drive(volumeMixer, vout, 1250)
  local pins = {
    { 250, 790, "step 1 contributes 0 (register 0x4F)" },
    { 500, 900, "step 2 contributes 11 (register 0x5A)" },
    { 750, 1020, "step 3 contributes 22 (register 0x66)" },
    { 1000, 1150, "step 4 contributes 33 (register 0x73)" },
    { 1250, 1260, "step 5 contributes 41 (register 0x7E)" },
  }
  for _, pin in ipairs(pins) do
    Assert.equal(leftAt(vout, pin[1]), pin[2], "LFO volume pin frame " .. pin[1] .. ": " .. pin[3])
  end
end

-- ExChannelSweepUpdate: the sweep contribution is sweepPitch*
-- (sweepLength - sweepCounter)/sweepLength with the counter advancing per
-- control step while autoSweep is set (pitch 768, 768, 576, 384, 192 over
-- sweepLength 4 -> timers 256, 256, 304, 362, 430 from the 512 base timer);
-- without autoSweep the counter stays and the pitch holds at the first
-- contribution (timer 256).
function T.sweep_ramps_pitch_over_its_length()
  local function run(autoSweep, frames)
    local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
    mixer:noteOn(spec({
      pcm = WAVE16,
      baseTimer = 512,
      loop = { startFrame = 0, endFrame = 16 },
      sweepPitch = 768,
      sweepLength = 4,
      autoSweep = autoSweep,
      pan = 0,
    }))
    local out = {}
    drive(mixer, out, frames)
    return out
  end
  local out = run(true, 1300)
  local pins = {
    { 251, 500, "step 2 reads at the doubled-rate position (timer 256)" },
    { 501, 1000, "step 3 (timer 304)" },
    { 751, 900, "step 4 (timer 362)" },
    { 1001, 1100, "step 5 (timer 430)" },
    { 1251, 500, "the sweep completed (timer 512)" },
  }
  for _, pin in ipairs(pins) do
    Assert.equal(leftAt(out, pin[1]), pin[2], "sweep pin frame " .. pin[1] .. ": " .. pin[3])
  end
  local held = run(false, 1300)
  local heldPins = {
    { 501, 1000, "without autoSweep the pitch stays at the first contribution" },
    { 751, 1500, "without autoSweep the pitch stays at the first contribution" },
    { 1001, 400, "without autoSweep the pitch stays at the first contribution" },
    { 1251, 900, "without autoSweep the pitch stays at the first contribution" },
  }
  for _, pin in ipairs(heldPins) do
    Assert.equal(leftAt(held, pin[1]), pin[2], "held sweep pin frame " .. pin[1] .. ": " .. pin[3])
  end
end

-- The generation is persistent per-channel state, not victim-derived:
-- a naturally dead one-shot frees the channel entry, but the next
-- allocation on that channel keeps incrementing the generation, so the
-- stale handle from before the death can never alias the new voice. The
-- reuse-after-steal tests above cover the occupied-victim path.
function T.natural_death_does_not_reuse_the_old_generation()
  local mixer = newMixer()
  -- Base timer 16 advances the read fast (CLK/(16*48000) ~= 21.8 samples per
  -- frame), so the one-shot dies within the first rendered frame and the
  -- channel is free for the next allocation.
  local oneShot = { loopEnabled = false, loop = { startFrame = 0, endFrame = 8 }, baseTimer = 16 }
  local h1 = mixer:noteOn(spec(oneShot)) --[[@as { channel: integer, generation: integer }]]
  mixer:render(12)
  local h2 = mixer:noteOn(spec(oneShot)) --[[@as { channel: integer, generation: integer }]]
  Assert.equal(h2.channel, h1.channel, "the second voice reuses the naturally freed channel")
  Assert.isTrue(h2.generation ~= h1.generation, "a freed channel never reuses the old generation")
  mixer:render(12)
  local h3 = mixer:noteOn(spec({ pcm = CONST_4096, pan = 0 })) --[[@as { channel: integer, generation: integer }]]
  Assert.equal(h3.channel, h1.channel, "the third voice reuses the same channel again")
  Assert.isTrue(h3.generation ~= h1.generation, "the generation keeps moving after the second natural death")
  Assert.isTrue(h3.generation ~= h2.generation, "the generation keeps moving after the second natural death")
  mixer:noteOff(h1)
  mixer:updateVoice(h1, { trackVolume = 0 })
  local out = mixer:render(300)
  Assert.equal(leftAt(out, 251), 4096, "the stale noteOff and updateVoice leave the replacement voice untouched")
  Assert.equal(leftAt(out, 300), 4096, "the replacement never enters release")
  Assert.isFalse(mixer:isVoiceAlive(h1), "the stale handle is not alive")
  Assert.isTrue(mixer:isVoiceAlive(h3), "the replacement voice is alive")
  mixer:noteOff(h3)
  mixer:render(600)
end

-- A tied re-note mutates one physical channel exactly as TrackPlayNote
-- does: the semantic retarget applies the key/velocity and the envelope
-- overrides without resetting the envelope stage or the sample phase, and
-- the sweep counter reset restores the full sweep contribution -- all on
-- the SAME voice generation, never a second allocation or a release. The
-- pins mirror the proven retune/sweep rows of this suite; the reset and
-- no-advance proofs are frame-exact comparisons between identical-length
-- runs, so the observable is the read rate (which the sweep counter
-- controls), never a hand-derived sample.
local function tiedSweepSpec()
  return spec({
    pcm = WAVE16,
    baseTimer = 512,
    loop = { startFrame = 0, endFrame = 16 },
    pan = 0,
    sweepPitch = 768,
    sweepLength = 4,
    autoSweep = false,
  })
end

-- Renders `frames` frames of a fresh tied sweep voice after the given
-- sweep-counter setup: `advances` advanceTrackTick calls, then
-- `syncs` control steps interleaved with 250-frame renders. The
-- `retargetAtFirstSync` flag applies the common-tail reset (sweepCounter
-- 0) before the first control step instead of leaving the counter at its
-- advanced position.
local function tiedSweepRun(advances, syncs, retargetAtFirstSync)
  local mixer = newMixer()
  local handle = mixer:noteOn(tiedSweepSpec()) --[[@as { channel: integer, generation: integer }]]
  local out = {}
  mixer:renderInto(out, 250) -- the noteOn's own step (counter 0)
  for _ = 1, advances do
    mixer:advanceTrackTick(handle)
  end
  for step = 1, syncs do
    if retargetAtFirstSync and step == 1 then
      mixer:retargetTiedVoice(handle, {
        key = 60,
        velocity = 127,
        sweepPitch = 768,
        sweepLength = 4,
        autoSweep = false,
        sweepCounter = 0,
      })
    end
    mixer:controlStep()
    mixer:renderInto(out, 250)
  end
  return out
end

local function sameRow(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

function T.retargeted_tied_voices_apply_the_full_common_tail_at_the_next_control_step()
  -- The counter reset restores the counter-0 read rate: a run whose counter
  -- was advanced to 2 and then retargeted back to 0 renders exactly like a
  -- run whose counter never moved, while the un-retargeted advanced run
  -- reads at the counter-2 rate (a different row).
  local baseline = tiedSweepRun(0, 3, false)
  local advanced = tiedSweepRun(2, 3, false)
  local reset = tiedSweepRun(2, 3, true)
  Assert.isFalse(sameRow(advanced, baseline), "the advanced counter reads at a different rate")
  Assert.isTrue(sameRow(reset, baseline), "the counter reset restores the counter-0 contribution exactly")
  -- The retarget never releases or reallocates: the voice stays alive on
  -- its original generation across the retarget and the control steps.
  local mixer = newMixer()
  local handle = mixer:noteOn(tiedSweepSpec()) --[[@as { channel: integer, generation: integer }]]
  local out = {}
  mixer:renderInto(out, 250)
  mixer:advanceTrackTick(handle)
  mixer:controlStep()
  mixer:retargetTiedVoice(handle, {
    key = 60,
    velocity = 127,
    sweepPitch = 768,
    sweepLength = 4,
    autoSweep = false,
    sweepCounter = 0,
  })
  mixer:controlStep()
  mixer:renderInto(out, 250)
  Assert.isTrue(mixer:isVoiceAlive(handle), "the retargeted voice stays alive on the same generation")
  -- Envelope and wave continuity on a key retarget: the proven key-72
  -- retune pins hold through the retarget -- the sample position continues
  -- and the attack curve continues from the step it was on (the retarget
  -- carries the same envelope overrides, so the coefficients are unchanged
  -- and the stage never restarts).
  local envMixer = newMixer()
  local envHandle = envMixer:noteOn(spec({
    -- A constant wave isolates the envelope register progression from the
    -- key-72 retarget's doubled read rate (the pins mirror the retune
    -- test's rows; the sample position never enters the expected values).
    pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 },
    baseTimer = 512,
    loop = { startFrame = 0, endFrame = 8 },
    pan = 0,
    envelope = { attack = 100, decay = 127, sustain = 127, release = 127 },
  })) --[[@as { channel: integer, generation: integer }]]
  local first = {}
  envMixer:renderInto(first, 250)
  envMixer:controlStep()
  envMixer:renderInto(first, 250)
  envMixer:retargetTiedVoice(envHandle, {
    key = 72,
    velocity = 127,
    envelope = { attack = 100, decay = 127, sustain = 127, release = 127 },
  })
  envMixer:controlStep()
  local second = {}
  drive(envMixer, second, 750)
  Assert.equal(leftAt(first, 250), 13, "attack 100 step 1 holds register 0x30D through the first block")
  Assert.equal(leftAt(first, 251), 96, "attack step 2 reaches register 0x360")
  Assert.equal(leftAt(second, 250), 320, "the retarget leaves the step-3 register untouched")
  Assert.equal(leftAt(second, 251), 664, "attack step 4 continues from the retargeted voice")
  Assert.equal(leftAt(second, 750), 1040, "the attack continues toward the sustain register")
  Assert.isTrue(envMixer:isVoiceAlive(envHandle), "the key-retargeted voice stays alive")
end

return { tests = T }
