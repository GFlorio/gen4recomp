-- VoiceMixer rendering-core contract: a deterministic 16-channel DS sound
-- engine per the ARM7 NitroSDK (tmp/refs/pokediamond/arm7/lib/src/
-- SND_exChannel.c, SND_util.c, SND_bank.c, SND_seq.c) and GBATEK ("DS
-- Sound" chapter). The mixer owns per-voice NNS channel behavior and the
-- physical host boundary; allocation, per-note control updates, LFO and
-- sweep live in the sibling voice_mixer_alloc_test.lua suite.
--   * Volume is a dB-like integer sum per control step
--     (SNDi_DecibelSquareTable[velocity] + envAttenuation>>7
--     + DecibelSquare[trackVolume] + DecibelSquare[expression]
--     + DecibelSquare[playerVolume] + fader), converted once per step by
--     SND_CalcChannelVolume; no per-stage float gain.
--   * The envelope is the SDK state machine (SND_SetExChannelAttack
--     coefficients and the 19-entry high table, CalcDecayCoeff decay/release
--     with the 127/126 special cases, DecibelSquare[sustain]<<7 target,
--     release stopped at the SDK vol <= -723 threshold), advanced once per
--     control step -- 192 Hz, i.e. one step per 250 output frames at 48 kHz
--     (SND_TIMER_RATE 240 at the 192 Hz sound interval, the cadence the
--     sequence player already derives its tick clock from). The noteOn
--     itself is the note's first control step; subsequent steps fire every
--     CONTROL_PERIOD frames on the mixer's absolute frame count.
--   * Pitch is the integer domain (key - originalKey)*0x40 with
--     SND_CalcTimer(baseTimer, pitch) (BIOS pitch table); PSG timers are
--     masked with 0xFFFC; PSG/noise use the 8006 base timer. The host phase
--     increment is sampleRate*baseTimer/(timer*outputRate) -- the calculated
--     NDS timer feeds the physical boundary, never a MIDI frequency.
--   * Pan has three distinct domains: the instrument pan (0..127,
--     initPan = pan-64), the track pan offset (starts 0), and the final
--     hardware register (initPan + userPan + 0x40, clamped 0..127). The
--     register feeds the linear hardware mix L=(128-N)/128, R=N/128 with
--     register 127 interpreted as N=128 (GBATEK "7bit Volume and Panning
--     Values").
--   * Square duty stays the discrete 0..7 index (8-sample cycle starting at
--     LOW, HIGH=(d+1)*12.5%); noise is the 15-bit LFSR from 7FFFh.
-- Output is interleaved stereo int16; mixing sums and saturates at
-- +-32767/+-32768; per-voice host gains use the register mantissa N/128 and
-- the divider shift {0,1,2,4}. Commands between renders apply at the next
-- control step; rendering is independent of chunk size.
--
-- The voice/spec shapes follow the frozen contracts: voice = {generator,
-- originalKey, envelope, pan}; sample descriptor = {schema, key, file,
-- frames, sampleRate, baseTimer, loopEnabled, loop}. Every expected value
-- below is a known vector transcribed from the SDK sources or the NDS ARM7
-- BIOS tables (getpitchtbl/getvoltbl hardware dumps); the tests never
-- reimplement the SDK algorithms.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")

local T = {}

local SAMPLE_RATE = 48000

-- Distinct small-amplitude waves so voice sums never clip and every voice is
-- identifiable in the mix.
local WAVE_A = { 100, 200, 300, 400, 500, 600, 700, 800 }
local WAVE16 = {}
for i = 1, 16 do
  WAVE16[i] = i * 100
end
-- Constant waves for the volume-path and pan-register pins: every expected
-- register gain below is an exact integer multiple of the sample, so the
-- pinned products (sample * N/128 / 2^shift * pan mix) are exact.
local CONST_5120 = { 5120, 5120, 5120, 5120, 5120, 5120, 5120, 5120 }
local CONST_6400 = { 6400, 6400, 6400, 6400, 6400, 6400, 6400, 6400 }

local function newMixer(rate)
  return VoiceMixer.new({ sampleRate = rate or SAMPLE_RATE })
end

-- The frozen voice shape plus the per-note inputs: generator, originalKey,
-- envelope, pan, key, velocity, trackVolume/expression/playerVolume,
-- channelMask, trackPriority, playerPriority, and the optional channel-side
-- controls (trackPanOffset 0, panRange 127, fader 0, sweepPitch 0,
-- sweepLength 0, autoSweep true, lfo {target 0=pitch/1=volume/2=pan,
-- depth 0, range 1, speed 16, delay 0}).
local function spec(overrides)
  local s = {
    generator = { kind = "sample", sample = AudioFixture.key(1) },
    pcm = AudioFixture.pcm16le(WAVE_A),
    sampleRate = SAMPLE_RATE,
    baseTimer = 8006,
    loopEnabled = true,
    loop = { startFrame = 0, endFrame = 8 },
    key = 60,
    originalKey = 60,
    velocity = 127,
    trackVolume = 127,
    expression = 127,
    playerVolume = 127,
    envelope = { attack = 127, decay = 127, sustain = 127, release = 127 },
    pan = 64,
    channelMask = 0xFFFF,
    trackPriority = 64,
    playerPriority = 64,
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

function T.renders_silence_without_voices()
  local mixer = newMixer()
  local pcm = mixer:render(32)
  Assert.equal(#pcm, 64)
  for i = 1, 64 do
    Assert.equal(pcm[i], 0, "no voices, no sound")
  end
end

-- The exact NNS volume path: velocity through SNDi_DecibelSquareTable, the
-- envelope attenuation (0 after the instant attack), the track volume, the
-- expression (second volume) and the player volume, all summed in the
-- dB-like integer domain (SND_seq.c TrackUpdateChannel), plus the external
-- fader, converted once by SND_CalcChannelVolume. Expected values are the
-- volume register mantissa N/128 (register 127 = N 128) divided by
-- sSampleDataShiftTable {0,1,2,4} -- GBATEK "7bit Volume and Panning
-- Values" and "Channel/Mixer Bit-Widths".
function T.volume_path_sums_the_nns_decibel_domain()
  local function renderWith(overrides, frames)
    local mixer = newMixer()
    local merged = { pcm = AudioFixture.pcm16le(CONST_5120), pan = 0 }
    for key, value in pairs(overrides or {}) do
      merged[key] = value
    end
    mixer:noteOn(spec(merged))
    return mixer:render(frames)
  end
  local cases = {
    { name = "all 127 is the full register", overrides = {}, expected = 5120 },
    { name = "velocity 64 (db[64] = -119 -> 0x141)", overrides = { velocity = 64 }, expected = 1300 },
    { name = "track volume 64 is the same decibel point", overrides = { trackVolume = 64 }, expected = 1300 },
    { name = "expression 100 (db[100] = -42 -> 0x4F)", overrides = { expression = 100 }, expected = 3160 },
    { name = "player volume 100 is the same decibel point", overrides = { playerVolume = 100 }, expected = 3160 },
    {
      name = "all 100 sums four equal -42 terms (-168 -> 0x24A)",
      overrides = { velocity = 100, trackVolume = 100, expression = 100, playerVolume = 100 },
      expected = 740,
    },
    { name = "velocity 0 (db[0] = -32768 -> 0x300 silence)", overrides = { velocity = 0 }, expected = 0 },
    {
      name = "all 0 is silence",
      overrides = { velocity = 0, trackVolume = 0, expression = 0, playerVolume = 0 },
      expected = 0,
    },
    { name = "fader -200 (-200 -> 0x233)", overrides = { fader = -200 }, expected = 510 },
    { name = "fader far below the floor clamps to silence", overrides = { fader = -40000 }, expected = 0 },
  }
  for _, case in ipairs(cases) do
    local pcm = renderWith(case.overrides, 1)
    Assert.equal(leftAt(pcm, 1), case.expected, case.name)
    Assert.equal(rightAt(pcm, 1), 0, case.name .. " (pan 0)")
  end
end

-- The three pan domains stay distinct: the instrument pan (SND_NoteOn
-- initPan = pan - 64), the track pan offset (TrackUpdateChannel, starts 0),
-- and the hardware register (SND_ExChannelMain: initPan + userPan + 0x40
-- clamped 0..127; panRange scaling of the offset when panRange != 127).
-- The register feeds the linear hardware mix (128-N)/128 and N/128 with
-- register 127 read as N=128, so the center is half volume on each side,
-- not a full-gain curve.
function T.pan_registers_combine_instrument_track_and_hardware_domains()
  local function renderAt(overrides)
    local mixer = newMixer()
    local merged = { pcm = AudioFixture.pcm16le(CONST_6400) }
    for key, value in pairs(overrides or {}) do
      merged[key] = value
    end
    mixer:noteOn(spec(merged))
    return mixer:render(1)
  end
  local cases = {
    { name = "instrument 0 is the left extreme", overrides = { pan = 0 }, left = 6400, right = 0 },
    { name = "instrument 127 is the right extreme", overrides = { pan = 127 }, left = 0, right = 6400 },
    { name = "instrument 64 is half volume on both sides", overrides = { pan = 64 }, left = 3200, right = 3200 },
    { name = "register 63 is the asymmetric linear point", overrides = { pan = 63 }, left = 3250, right = 3150 },
    { name = "register 126 leaves 1/64 on the left", overrides = { pan = 126 }, left = 100, right = 6300 },
    { name = "instrument 100 with no track offset", overrides = { pan = 100 }, left = 1400, right = 5000 },
    {
      name = "instrument 64 plus a positive track offset",
      overrides = { pan = 64, trackPanOffset = 63 },
      left = 0,
      right = 6400,
    },
    {
      name = "instrument 64 plus a negative track offset",
      overrides = { pan = 64, trackPanOffset = -64 },
      left = 6400,
      right = 0,
    },
    {
      name = "instrument 0 plus a positive offset reaches center",
      overrides = { pan = 0, trackPanOffset = 64 },
      left = 3200,
      right = 3200,
    },
    { name = "clamping at the right extreme", overrides = { pan = 127, trackPanOffset = 64 }, left = 0, right = 6400 },
    { name = "clamping at the left extreme", overrides = { pan = 64, trackPanOffset = -127 }, left = 6400, right = 0 },
    {
      name = "pan range scales the track offset only",
      overrides = { pan = 64, trackPanOffset = 32, panRange = 64 },
      left = 2400,
      right = 4000,
    },
  }
  for _, case in ipairs(cases) do
    local pcm = renderAt(case.overrides)
    Assert.equal(leftAt(pcm, 1), case.left, case.name)
    Assert.equal(rightAt(pcm, 1), case.right, case.name)
  end
end

-- SND_SetExChannelAttack: attack 100 maps to the 255-attack branch
-- (coefficient 155); the envelope runs envAttenuation =
-- -((-envAttenuation * coeff) >> 8) once per control step (250 output
-- frames), reaching 0 after exactly 22 steps (known recurrence vectors:
-- env -438, -266, -161, -5 at steps 1, 2, 3, 10, register 0x30D, 0x360,
-- 0x250, 0x79). The first step applies at noteOn; the envelope never
-- advances once per output sample.
function T.envelope_attack_uses_the_sdk_recurrence_at_the_control_cadence()
  local mixer = newMixer()
  local pcm = AudioFixture.pcm16le({ 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 })
  mixer:noteOn(spec({ pcm = pcm, pan = 0, envelope = { attack = 100, decay = 127, sustain = 127, release = 127 } }))
  local out = mixer:render(5750)
  local pins = {
    { 250, 13, "step 1 (env -438, register 0x30D)" },
    { 500, 96, "step 2 (env -266, register 0x360)" },
    { 750, 320, "step 3 (env -161, register 0x250)" },
    { 2500, 1936, "step 10 (env -5, register 0x79)" },
    { 5500, 2048, "step 22 completes the attack (env 0, register 0x7F)" },
    { 5750, 2048, "sustain 127 holds the full register" },
  }
  for _, pin in ipairs(pins) do
    Assert.equal(leftAt(out, pin[1]), pin[2], "attack pin frame " .. pin[1] .. ": " .. pin[3])
  end

  local fast = newMixer()
  fast:noteOn(spec({ pcm = pcm, pan = 0, envelope = { attack = 120, decay = 127, sustain = 127, release = 127 } }))
  local fastOut = fast:render(2000)
  Assert.equal(leftAt(fastOut, 250), 264, "attack 120 uses the high-range table coefficient 63 (register 0x242)")
  Assert.equal(leftAt(fastOut, 500), 1232, "attack 120 step 2 (register 0x4D)")
  Assert.equal(leftAt(fastOut, 2000), 2048, "attack 120 completes after 8 steps")
end

-- SND_UpdateExChannelEnvelope decay: with sustain 64 the envelope moves
-- toward DecibelSquare[64] << 7 = -15232 (env -119), decrementing by the
-- CalcDecayCoeff(100) = 295 value per control step and clamping to the
-- target (register 0x141 = 65/256) instead of passing through env -120
-- (0x140); sustain holds the clamped value.
function T.envelope_decay_clamps_to_the_sustain_target()
  local mixer = newMixer()
  local pcm = AudioFixture.pcm16le({ 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 })
  mixer:noteOn(spec({ pcm = pcm, pan = 0, envelope = { attack = 127, decay = 100, sustain = 64, release = 127 } }))
  local out = mixer:render(13500)
  local pins = {
    { 250, 2048, "attack 127 is instant" },
    { 500, 1984, "decay step 1 (env -3, register 0x7C)" },
    { 1000, 1888, "decay step 3 (env -7, register 0x76)" },
    { 13000, 528, "decay step 51 (env -118, register 0x142)" },
    { 13250, 520, "decay step 52 clamps to the sustain target (register 0x141)" },
    { 13500, 520, "sustain holds the target" },
  }
  for _, pin in ipairs(pins) do
    Assert.equal(leftAt(out, pin[1]), pin[2], "decay pin frame " .. pin[1] .. ": " .. pin[3])
  end
end

-- SND_ReleaseExChannel release: the envelope decrements by the
-- CalcDecayCoeff(release) value per control step; the channel stops when
-- the dB sum crosses the SDK threshold vol <= -723 (SND_VOL_DB_MIN), so a
-- quieter velocity reaches the threshold sooner. Release 127 (coeff
-- 0xFFFF) takes one step to the near-silent register 0x306 and one more to
-- stop; the noteOff itself never kills the voice -- the first release step
-- fires at the next control step (noteOff here lands between steps 2 and 3,
-- at frame 300).
function T.envelope_release_decays_to_the_sdk_stop_threshold()
  local pcm = AudioFixture.pcm16le({ 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 })
  local function releaseRun(velocity, releaseByte, frames)
    local mixer = newMixer()
    local handle = mixer:noteOn(spec({
      pcm = pcm,
      pan = 0,
      velocity = velocity,
      envelope = { attack = 127, decay = 127, sustain = 127, release = releaseByte },
    })) --[[@as { channel: integer, generation: integer }]]
    mixer:render(300)
    mixer:noteOff(handle)
    return mixer:render(frames)
  end
  local before = releaseRun(127, 100, 200)
  Assert.equal(leftAt(before, 200), 2048, "the voice holds until the release step")
  local out = releaseRun(127, 100, 78700)
  Assert.equal(leftAt(out, 78201), 1, "velocity 127: last sounding release step (register 0x301)")
  Assert.equal(leftAt(out, 78451), 0, "velocity 127: stop at release step 314 (vol <= -723)")
  local quiet = releaseRun(64, 100, 65700)
  Assert.equal(leftAt(quiet, 200), 520, "velocity 64 sustains at register 0x141 until the release step")
  Assert.equal(leftAt(quiet, 65201), 1, "velocity 64: last sounding release step (register 0x301)")
  Assert.equal(leftAt(quiet, 65451), 0, "velocity 64: stop at release step 262")
  local fast = releaseRun(127, 127, 700)
  Assert.equal(leftAt(fast, 201), 6, "release 127: one step at register 0x306")
  Assert.equal(leftAt(fast, 451), 0, "release 127: stops on the second release step")
end

-- Pitch is the integer domain (key - originalKey)*0x40 through
-- SND_CalcTimer(baseTimer, pitch) (NDS ARM7 BIOS pitch table); the host
-- phase increment is sampleRate*baseTimer/(timer*outputRate), so at the
-- octaves the ratios are exactly 2 and 1/2, and one semitone up (timer
-- 7556) drifts the read position by the exact rational 8006/7556 (frame 18
-- reads the third sample while unity reads the second).
function T.sample_voices_pitch_through_the_calculated_timer()
  local function renderAt(key, frames)
    local mixer = newMixer()
    mixer:noteOn(
      spec({ pcm = AudioFixture.pcm16le(WAVE16), loop = { startFrame = 0, endFrame = 16 }, key = key, pan = 0 })
    )
    return mixer:render(frames)
  end
  local pcm = renderAt(60, 8)
  for frame = 1, 8 do
    Assert.equal(leftAt(pcm, frame), WAVE16[frame], "key 60 plays the wave at unity pitch")
  end
  local up = renderAt(72, 8)
  local expectedUp = { 100, 300, 500, 700, 900, 1100, 1300, 1500 }
  for frame = 1, 8 do
    Assert.equal(leftAt(up, frame), expectedUp[frame], "an octave up reads every other sample (timer 4003)")
  end
  local down = renderAt(48, 8)
  local expectedDown = { 100, 100, 200, 200, 300, 300, 400, 400 }
  for frame = 1, 8 do
    Assert.equal(leftAt(down, frame), expectedDown[frame], "an octave down reads each sample twice (timer 16012)")
  end
  local sharp = renderAt(61, 20)
  for frame = 1, 17 do
    Assert.equal(leftAt(sharp, frame), WAVE16[(frame - 1) % 16 + 1], "one semitone up matches unity early")
  end
  Assert.equal(leftAt(sharp, 18), 300, "one semitone up reads the third sample at frame 18 (timer 7556)")
end

-- PSG runs only on channels 8..13 and noise only on 14..15, both with the
-- 8006 base timer at the original key (never 2^((key-60)/12)); the square
-- timer is masked with 0xFFFC. At a 16756991 Hz mixer rate the DS sample
-- clock translation is exactly 1/timer, so the duty-cycle boundaries and
-- the 15-bit noise LFSR land on exact frames: duty d starts LOW for
-- (7-d)*timer frames then HIGH for (d+1)*timer frames; the LFSR from
-- 7FFFh outputs 14 LOW states then a HIGH run (GBATEK noise LFSR).
function T.psg_and_noise_use_the_base_timer_masks_and_lfsr()
  local DS_RATE = 16756991
  local function squareAt(duty, key, frames)
    local mixer = newMixer(DS_RATE)
    mixer:noteOn(spec({ generator = { kind = "square", duty = duty }, key = key, channelMask = 0x3F00, pan = 0 }))
    return mixer:render(frames)
  end
  local out = squareAt(1 / 8, 60, 64033)
  Assert.equal(leftAt(out, 56028), -32767, "key 60 duty 0: LOW through frame 7*8004 (masked timer)")
  Assert.equal(leftAt(out, 56029), 32767, "key 60 duty 0: HIGH from frame 7*8004+1")
  Assert.equal(leftAt(out, 64032), 32767, "key 60 duty 0: HIGH through frame 8*8004")
  Assert.equal(leftAt(out, 64033), -32767, "key 60 duty 0: the cycle restarts LOW")
  local octave = squareAt(1 / 8, 72, 32001)
  Assert.equal(leftAt(octave, 28000), -32767, "key 72 (timer 4000): LOW through frame 7*4000")
  Assert.equal(leftAt(octave, 28001), 32767, "key 72: HIGH from frame 7*4000+1")
  local masked = squareAt(1 / 8, 59, 59376)
  Assert.equal(leftAt(masked, 59360), -32767, "key 59: the masked timer 8480 keeps frame 7*8480 LOW")
  Assert.equal(leftAt(masked, 59361), 32767, "key 59: the masked timer 8480 turns HIGH at frame 7*8480+1")
  local noise = newMixer(DS_RATE)
  noise:noteOn(spec({ generator = { kind = "noise" }, key = 60, channelMask = 0xC000, pan = 0 }))
  local noisePcm = noise:render(128097)
  Assert.equal(leftAt(noisePcm, 112084), -32767, "noise: 14 LOW LFSR states through frame 14*8006")
  Assert.equal(leftAt(noisePcm, 112085), 32767, "noise: the HIGH run starts at frame 14*8006+1")
  Assert.equal(leftAt(noisePcm, 128096), 32767, "noise: HIGH through state 15")
  Assert.equal(leftAt(noisePcm, 128097), 32767, "noise: the LFSR run continues past state 15")
end

-- Sample voices start at the sample start and wrap inside their loop
-- window; a one-shot wave stops at the window end; a looping voice holds
-- until noteOff, whose release follows the control cadence.
function T.loops_wrap_inside_the_window_and_one_shots_stop()
  local mixer = newMixer()
  mixer:noteOn(spec({ loop = { startFrame = 2, endFrame = 6 }, pan = 0 }))
  local pcm = mixer:render(8)
  Assert.equal(leftAt(pcm, 7), 300, "the voice plays the pre-loop region first, then wraps into the window")
  Assert.equal(leftAt(pcm, 8), 400, "the loop window repeats")

  local oneShot = newMixer()
  oneShot:noteOn(spec({ loopEnabled = false, pan = 0 }))
  local shot = oneShot:render(12)
  Assert.equal(leftAt(shot, 8), 800, "the one-shot wave plays its window")
  Assert.equal(leftAt(shot, 12), 0, "the one-shot stops at the window end")

  local held = newMixer()
  local pcm2048 = AudioFixture.pcm16le({ 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 })
  local handle = held:noteOn(spec({ pcm = pcm2048, pan = 0 })) --[[@as { channel: integer, generation: integer }]]
  local before = held:render(12)
  Assert.equal(leftAt(before, 12), 2048, "the looping voice holds")
  held:noteOff(handle)
  local after = held:render(500)
  Assert.equal(leftAt(after, 238), 2048, "the voice keeps sounding until the next control step")
  Assert.equal(leftAt(after, 239), 6, "release 127 reaches register 0x306 at the control step")
  Assert.equal(leftAt(after, 489), 0, "release 127 stops the voice on the following control step")
end

function T.mixing_sums_saturates_and_rendering_is_chunk_independent()
  local mixer = newMixer()
  local loud = { 30000, -30000, 30000, -30000, 30000, -30000, 30000, -30000 }
  mixer:noteOn(spec({ pcm = AudioFixture.pcm16le(loud), pan = 0 }))
  mixer:noteOn(spec({ pcm = AudioFixture.pcm16le(loud), pan = 0 }))
  local pcm = mixer:render(8)
  local expected = { 32767, -32768, 32767, -32768, 32767, -32768, 32767, -32768 }
  for frame = 1, 8 do
    Assert.equal(leftAt(pcm, frame), expected[frame], "the mix saturates at the int16 bounds")
  end

  local function playChunked(chunks)
    local m = newMixer()
    m:noteOn(spec({
      pcm = AudioFixture.pcm16le({ 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }),
      pan = 0,
      envelope = { attack = 0, decay = 127, sustain = 127, release = 127 },
    }))
    local out = {}
    for _, frames in ipairs(chunks) do
      local part = m:render(frames)
      for i = 1, #part do
        out[#out + 1] = part[i]
      end
    end
    return out
  end
  local whole = playChunked({ 400 })
  local split = playChunked({ 200, 200 })
  Assert.deepEqual(whole, split, "chunk boundaries do not move the control steps")
  local left = playChunked({ 120 })
  local right = playChunked({ 40, 40, 40 })
  Assert.deepEqual(left, right, "chunk size does not change the rendered PCM")
end

-- The transport pause hook (the NNS SND_PlayerPause the sequence player's
-- pausePlayer uses): a suspended voice reads nothing, advances nothing, and
-- runs no control steps -- its sample position and envelope freeze in place
-- -- and resumes exactly where it stopped.
function T.suspended_voices_freeze_in_place_and_resume_exactly()
  local mixer = newMixer()
  local handle = mixer:noteOn(spec({ pan = 0 })) --[[@as { channel: integer, generation: integer }]]
  local before = mixer:render(200)
  Assert.equal(leftAt(before, 200), WAVE_A[(200 - 1) % 8 + 1], "the voice sounds before the suspension")
  mixer:suspendVoice(handle, true)
  local held = mixer:render(100)
  for frame = 1, 100 do
    Assert.equal(leftAt(held, frame), 0, "the suspended voice contributes nothing")
  end
  mixer:suspendVoice(handle, false)
  local resumed = mixer:render(50)
  Assert.equal(
    leftAt(resumed, 50),
    WAVE_A[(200 + 50 - 1) % 8 + 1],
    "the voice resumes at the sample position it froze at"
  )
end

-- A note-off on a suspended voice un-suspends it: the release must always
-- ring out and free the channel, never leak a suspended voice that no
-- render can reach.
function T.note_off_un_suspends_a_voice_so_its_release_proceeds()
  local mixer = newMixer()
  local handle = mixer:noteOn(spec({ pan = 0 })) --[[@as { channel: integer, generation: integer }]]
  mixer:render(100)
  mixer:suspendVoice(handle, true)
  mixer:noteOff(handle)
  local tail = mixer:render(600)
  local sounding = 0
  for frame = 1, 600 do
    if leftAt(tail, frame) ~= 0 then
      sounding = sounding + 1
    end
  end
  Assert.isTrue(sounding > 0, "the release rings out instead of staying suspended")
  local after = mixer:render(100)
  for frame = 1, 100 do
    Assert.equal(leftAt(after, frame), 0, "the release ended and the channel freed")
  end
  local nextHandle = assert(mixer:noteOn(spec({ pan = 0 })))
  Assert.equal(nextHandle.channel, handle.channel, "the freed channel is reusable")
  local fresh = mixer:render(8)
  Assert.isTrue(leftAt(fresh, 1) ~= 0, "the fresh note sounds on the reused channel")
end

return { tests = T }
