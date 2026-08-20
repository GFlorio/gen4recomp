-- VoiceMixer rendering-core contract: a deterministic 16-channel DS sound
-- engine per the ARM7 NitroSDK (tmp/refs/pokediamond/arm7/lib/src/
-- SND_exChannel.c, SND_util.c, SND_bank.c, SND_seq.c) and GBATEK ("DS
-- Sound" chapter). The mixer owns per-voice NNS channel behavior and the
-- physical host boundary; allocation, per-note control updates, LFO and
-- sweep live in the sibling voice_mixer_alloc_test.lua suite.
--   * Volume is a dB-like integer sum per control step
--     (SNDi_DecibelSquareTable[velocity] + envAttenuation>>7
--     + DecibelSquare[trackVolume] + DecibelSquare[expression]
--     + DecibelSquare[sequenceVolume] + fader), converted once per step by
--     SND_CalcChannelVolume; no per-stage float gain.
--   * The envelope is the SDK state machine (SND_SetExChannelAttack
--     coefficients and the 19-entry high table, CalcDecayCoeff decay/release
--     with the 127/126 special cases, DecibelSquare[sustain]<<7 target,
--     release stopped at the control step whose current pre-register dB sum
--     crosses the vol <= -723 threshold (SND_VOL_DB_MIN)), advanced once per
--     control step -- exactly 192 Hz through the external integer phase
--     accumulator (phase += 192 per output frame, one step when it reaches
--     the output rate): 250-frame boundaries at 48 kHz and the 170/171
--     alternation at 32768 Hz. noteOn synchronizes initial registers without
--     consuming elapsed control time; controlStep advances the elapsed state.
--   * Pitch is the integer domain (key - originalKey)*0x40 with
--     SND_CalcTimer(baseTimer, pitch) (BIOS pitch table); PSG timers are
--     masked with 0xFFFC; PSG/noise use the 8006 base timer. The host phase
--     increment is the DS sample clock/(timer*outputRate) -- the calculated
--     NDS timer feeds the physical boundary, never a MIDI frequency and
--     never a source sample-rate header.
--   * Pan has three distinct domains: the instrument pan (0..127,
--     initPan = pan-64), the track pan offset (starts 0), and the final
--     hardware register (initPan + userPan + 0x40, clamped 0..127). The
--     register feeds the linear hardware mix L=(128-N)/128, R=N/128 with
--     register 127 interpreted as N=128 (GBATEK "7bit Volume and Panning
--     Values").
--   * Square duty is the discrete integer 0..7 index (8-sample cycle
--     starting at LOW, HIGH=(d+1)*12.5%; duty 7 is the all-LOW special
--     pattern); noise is the 15-bit LFSR from 7FFFh.
-- Output is interleaved stereo int16; mixing sums and saturates at
-- +-32767/+-32768; per-voice host gains use the register mantissa N/128 and
-- the divider shift {0,1,2,4}. Commands between renders apply at the next
-- control step; rendering is independent of chunk size.
--
-- The voice/spec shapes follow the agreed contracts: voice = {generator,
-- originalKey, envelope, pan}; the sample voice spec = {pcm, baseTimer,
-- loop, loopEnabled} -- no source sample rate (playback derives from the DS
-- clock and the calculated timer). Every expected value below is a known
-- vector transcribed from the SDK sources or the NDS ARM7 BIOS tables
-- (getpitchtbl/getvoltbl hardware dumps); the tests never reimplement the
-- SDK algorithms.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")

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

local function newMixer(rate, prime)
  local mixer = VoiceMixer.new({ sampleRate = rate or SAMPLE_RATE })
  -- Existing rendering vectors begin by sampling immediately after noteOn;
  -- keep those vectors focused on their stated math while the lifecycle tests
  -- below opt out and drive the first interval explicitly.
  if prime ~= false then
    local noteOn = mixer.noteOn
    ---@diagnostic disable-next-line: duplicate-set-field
    rawset(mixer, "noteOn", function(self, noteSpec)
      local handle = noteOn(self, noteSpec)
      if handle ~= nil then
        self:controlStep()
      end
      return handle
    end)
  end
  return mixer
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

function T.renders_silence_without_voices()
  local mixer = newMixer(nil, false)
  local pcm = mixer:render(32)
  Assert.equal(#pcm, 64)
  for i = 1, 64 do
    Assert.equal(pcm[i], 0, "no voices, no sound")
  end
end

-- Nitro initializes a new ExChannel's registers without advancing its
-- envelope. The first elapsed control interval performs the only attack/LFO
-- transition for that interval.
function T.note_on_initializes_without_consuming_the_first_control_interval()
  local mixer = newMixer(nil, false)
  local pcm = { 2048, 2048, 2048, 2048 }
  mixer:noteOn(spec({
    pcm = pcm,
    pan = 0,
    envelope = { attack = 100, decay = 127, sustain = 127, release = 127 },
  }))

  local before = mixer:render(1)
  Assert.equal(leftAt(before, 1), 0, "a fresh voice remains at the initialized envelope")

  mixer:controlStep()
  local after = mixer:render(1)
  Assert.equal(leftAt(after, 1), 13, "the first interval advances the attack exactly once")
end

function T.decay_coefficient_rejects_the_release_sentinel()
  Assert.throws(function()
    NnsSoundMath.decayCoefficient(255)
  end)
end

function T.release_sentinel_initializes_an_indefinite_voice()
  local state
  local mixer = VoiceMixer.new({
    sampleRate = SAMPLE_RATE,
    observer = {
      onChannelState = function(_, event)
        if event.active then
          state = event
        end
      end,
    },
  })
  local handle = mixer:noteOn(spec({
    envelope = { attack = 127, decay = 127, sustain = 127, release = 255 },
    length = 12,
  }))
  Assert.isTrue(handle ~= nil, "release sentinel note allocates")
  local liveHandle = assert(handle)
  mixer:controlStep()
  Assert.isTrue(mixer:isVoiceAlive(liveHandle), "release sentinel voice remains alive")
  Assert.equal(state.length, -1, "release sentinel uses an indefinite channel length")
end

-- The exact NNS volume path: velocity through SNDi_DecibelSquareTable, the
-- envelope attenuation (0 after the instant attack), the track volume, the
-- expression (second volume) and the sequence volume, all summed in the
-- dB-like integer domain (SND_seq.c TrackUpdateChannel), plus the external
-- fader, converted once by SND_CalcChannelVolume. Expected values are the
-- volume register mantissa N/128 (register 127 = N 128) divided by
-- sSampleDataShiftTable {0,1,2,4} -- GBATEK "7bit Volume and Panning
-- Values" and "Channel/Mixer Bit-Widths".
function T.volume_path_sums_the_nns_decibel_domain()
  local function renderWith(overrides, frames)
    local mixer = newMixer()
    local merged = { pcm = CONST_5120, pan = 0 }
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
    { name = "sequence volume 100 is the same decibel point", overrides = { sequenceVolume = 100 }, expected = 3160 },
    {
      name = "all 100 sums four equal -42 terms (-168 -> 0x24A)",
      overrides = { velocity = 100, trackVolume = 100, expression = 100, sequenceVolume = 100 },
      expected = 740,
    },
    { name = "velocity 0 (db[0] = -32768 -> 0x300 silence)", overrides = { velocity = 0 }, expected = 0 },
    {
      name = "all 0 is silence",
      overrides = { velocity = 0, trackVolume = 0, expression = 0, sequenceVolume = 0 },
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
    local merged = { pcm = CONST_6400 }
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
-- -((-envAttenuation * coeff) >> 8) once per explicit control step (every
-- 250 output frames at 48 kHz), reaching 0 after exactly 22 steps (known
-- recurrence vectors: env -438, -266, -161, -5 at steps 1, 2, 3, 10,
-- register 0x30D, 0x360, 0x250, 0x79). The first step applies at noteOn;
-- the envelope never advances once per output sample and never advances
-- inside renderInto -- the external scheduler drives the cadence (the C03
-- contract), so this test renders 249 frames and control-steps at the
-- 250-frame boundary the way the scheduler does.
function T.envelope_attack_uses_the_sdk_recurrence_at_the_control_cadence()
  local function drive(mixer, frames)
    local out = {}
    local remaining = frames
    while remaining > 0 do
      local span = math.min(remaining, 250)
      mixer:renderInto(out, span)
      remaining = remaining - span
      if remaining > 0 then
        mixer:controlStep()
      end
    end
    return out
  end
  local mixer = newMixer()
  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  mixer:noteOn(spec({ pcm = pcm, pan = 0, envelope = { attack = 100, decay = 127, sustain = 127, release = 127 } }))
  local out = drive(mixer, 5750)
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
  local fastOut = drive(fast, 2000)
  Assert.equal(leftAt(fastOut, 250), 264, "attack 120 uses the high-range table coefficient 63 (register 0x242)")
  Assert.equal(leftAt(fastOut, 500), 1232, "attack 120 step 2 (register 0x4D)")
  Assert.equal(leftAt(fastOut, 2000), 2048, "attack 120 completes after 8 steps")
end

-- SND_UpdateExChannelEnvelope decay: with sustain 64 the envelope moves
-- toward DecibelSquare[64] << 7 = -15232 (env -119), decrementing by the
-- CalcDecayCoeff(100) = 295 value per explicit control step (every 250
-- frames at 48 kHz) and clamping to the target (register 0x141 = 65/256)
-- instead of passing through env -120 (0x140); sustain holds the clamped
-- value. The render/control cadence is the external scheduler's, so the
-- steps are driven explicitly at the interval boundaries.
function T.envelope_decay_clamps_to_the_sustain_target()
  local function drive(mixer, frames)
    local out = {}
    local remaining = frames
    while remaining > 0 do
      local span = math.min(remaining, 250)
      mixer:renderInto(out, span)
      remaining = remaining - span
      if remaining > 0 then
        mixer:controlStep()
      end
    end
    return out
  end
  local mixer = newMixer()
  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  mixer:noteOn(spec({ pcm = pcm, pan = 0, envelope = { attack = 127, decay = 100, sustain = 64, release = 127 } }))
  local out = drive(mixer, 13500)
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
-- CalcDecayCoeff(release) value per explicit control step; the channel
-- stops when the dB sum crosses the SDK threshold vol <= -723
-- (SND_VOL_DB_MIN), so a quieter velocity reaches the threshold sooner.
-- Release 127 (coeff 0xFFFF) takes one step to the near-silent register
-- 0x306 and one more to stop; the noteOff itself never kills the voice --
-- the first release step fires at the next control step. The mixer no
-- longer owns a cadence: the external scheduler drives one controlStep per
-- 250-frame interval (the C03 contract), so each render block is followed
-- by an explicit step. In the pinned scenario the noteOff lands between
-- steps 2 and 3 of the envelope (after frame 300 of the first 250-frame
-- block, i.e. during the second interval), so the release's first step
-- fires at frame 500 instead of the old frame 300+250.
function T.envelope_release_decays_to_the_sdk_stop_threshold()
  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  local function driveBlock(mixer, out, frames)
    local remaining = frames
    while remaining > 0 do
      local span = math.min(remaining, 250)
      mixer:renderInto(out, span)
      remaining = remaining - span
      if remaining > 0 then
        mixer:controlStep()
      end
    end
  end
  local function releaseRun(velocity, releaseByte, frames)
    local mixer = newMixer()
    local handle = mixer:noteOn(spec({
      pcm = pcm,
      pan = 0,
      velocity = velocity,
      envelope = { attack = 127, decay = 127, sustain = 127, release = releaseByte },
    })) --[[@as { channel: integer, generation: integer }]]
    -- The first 250-frame block renders, then the first elapsed control step
    -- runs, then the noteOff lands mid-interval (old frame
    -- 300) -- the release's first step therefore fires at the next control
    -- step, at frame 500.
    local out = {}
    driveBlock(mixer, out, 250)
    mixer:controlStep()
    mixer:noteOff(handle)
    driveBlock(mixer, out, frames - 250)
    return out
  end
  local before = releaseRun(127, 100, 450)
  Assert.equal(leftAt(before, 200), 2048, "the voice holds until the release step")
  local out = releaseRun(127, 100, 78751)
  Assert.equal(leftAt(out, 78750), 1, "velocity 127: the 314th release step's boundary frame sounds register 0x301")
  Assert.equal(leftAt(out, 78751), 0, "velocity 127: the 314th release step (vol <= -723) removes the voice")
  local quiet = releaseRun(64, 100, 65751)
  Assert.equal(leftAt(quiet, 200), 520, "velocity 64 sustains at register 0x141 until the release step")
  Assert.equal(leftAt(quiet, 65750), 1, "velocity 64: the 262nd release step's boundary frame sounds register 0x301")
  Assert.equal(leftAt(quiet, 65751), 0, "velocity 64: the 262nd release step (vol <= -723) removes the voice")
  local fast = releaseRun(127, 127, 751)
  Assert.equal(leftAt(fast, 501), 6, "release 127: the first release step's register 0x306 sounds from frame 501")
  Assert.equal(leftAt(fast, 751), 0, "release 127: the second release step stops the voice")
end

-- Pitch is the integer domain (key - originalKey)*0x40 through
-- SND_CalcTimer(baseTimer, pitch) (NDS ARM7 BIOS pitch table); the host
-- phase increment is the DS sample clock/(timer*outputRate), so at a
-- DS-clock-rate mixer the read advances exactly 1/timer samples per frame:
-- an octave up (timer 4003) reads sample 2 at half the frames of unity
-- (timer 8006), an octave down (timer 16012) at twice the frames, and one
-- semitone up (timer 7556) is one sample ahead of unity by frame 16012.
function T.sample_voices_pitch_through_the_calculated_timer()
  local DS_RATE = 16756991
  local function renderAt(key, frames)
    local mixer = newMixer(DS_RATE)
    mixer:noteOn(spec({ pcm = WAVE16, loop = { startFrame = 0, endFrame = 16 }, key = key, pan = 0 }))
    return mixer:render(frames)
  end
  local unity = renderAt(60, 24018)
  Assert.equal(leftAt(unity, 8006), 100, "key 60 reads sample 1 at frame 8006 (timer 8006)")
  Assert.equal(leftAt(unity, 16012), 200, "key 60 reads sample 2 at frame 16012")
  Assert.equal(leftAt(unity, 24018), 300, "key 60 reads sample 3 at frame 24018")
  local up = renderAt(72, 12009)
  Assert.equal(leftAt(up, 4003), 100, "an octave up reads sample 1 at half the frames (timer 4003)")
  Assert.equal(leftAt(up, 8006), 200, "an octave up reads sample 2 at half the frames")
  Assert.equal(leftAt(up, 12009), 300, "an octave up reads sample 3 at half the frames")
  local down = renderAt(48, 32024)
  Assert.equal(leftAt(down, 16012), 100, "an octave down reads sample 1 at twice the frames (timer 16012)")
  Assert.equal(leftAt(down, 32024), 200, "an octave down reads sample 2 at twice the frames")
  local sharp = renderAt(61, 16012)
  Assert.equal(leftAt(sharp, 16012), 300, "one semitone up reads the third sample at frame 16012 (timer 7556)")
  Assert.equal(leftAt(unity, 16012), 200, "unity is still at the second sample")
end

-- The note spec carries the user pitch (TrackInit bend 0 -> userPitch 0,
-- TrackUpdateChannel: userPitch = pitchBend*(bendRange<<6)>>7) folded into
-- the same integer pitch path as the key difference, so userPitch 64 lands
-- the one-semitone timer 7556 and userPitch -768 the octave-down timer
-- 16012 through SND_CalcTimer; a spec without the field renders exactly
-- like userPitch 0.
function T.user_pitch_offsets_the_timer_at_note_on()
  local DS_RATE = 16756991
  local function renderAt(userPitch, frames)
    local mixer = newMixer(DS_RATE)
    mixer:noteOn(spec({ pcm = WAVE16, loop = { startFrame = 0, endFrame = 16 }, userPitch = userPitch, pan = 0 }))
    return mixer:render(frames)
  end
  local bent = renderAt(64, 15200)
  Assert.equal(leftAt(bent, 7600), 200, "userPitch 64 lands the one-semitone timer 7556 (sample 2)")
  Assert.equal(leftAt(bent, 15200), 300, "userPitch 64 reads sample 3 where the key-61 timer still reads sample 2")
  local down = renderAt(-768, 32200)
  Assert.equal(leftAt(down, 10000), 100, "userPitch -768 lands the octave-down timer 16012 (sample 1)")
  Assert.equal(leftAt(down, 20000), 200, "userPitch -768 reads sample 2 at frame 20000")
  Assert.equal(leftAt(down, 32200), 300, "userPitch -768 reads sample 3 at frame 32200")
  local absent = newMixer(DS_RATE)
  absent:noteOn(spec({ pcm = WAVE16, loop = { startFrame = 0, endFrame = 16 }, pan = 0 }))
  Assert.deepEqual(absent:render(24018), renderAt(0, 24018), "userPitch defaults to 0 when absent")
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
  local out = squareAt(0, 60, 64033)
  Assert.equal(leftAt(out, 56028), -32767, "key 60 duty 0: LOW through frame 7*8004 (masked timer)")
  Assert.equal(leftAt(out, 56029), 32767, "key 60 duty 0: HIGH from frame 7*8004+1")
  Assert.equal(leftAt(out, 64032), 32767, "key 60 duty 0: HIGH through frame 8*8004")
  Assert.equal(leftAt(out, 64033), -32767, "key 60 duty 0: the cycle restarts LOW")
  local octave = squareAt(0, 72, 32001)
  Assert.equal(leftAt(octave, 28000), -32767, "key 72 (timer 4000): LOW through frame 7*4000")
  Assert.equal(leftAt(octave, 28001), 32767, "key 72: HIGH from frame 7*4000+1")
  local masked = squareAt(0, 59, 59376)
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
-- until noteOff, whose release follows the control cadence. At a DS-rate
-- host with base timer 16 the read advances exactly one sample per 16
-- frames (the DS-clock ratio 1/16 is exact), so the window edges land on
-- exact frames: the pre-loop samples 1..2 play once, then the window
-- 3..6 repeats; the one-shot sounds its last sample at frame 128 and stops
-- at the window end.
function T.loops_wrap_inside_the_window_and_one_shots_stop()
  local DS_RATE = 16756991
  local loopMixer = newMixer(DS_RATE)
  loopMixer:noteOn(spec({ baseTimer = 16, loop = { startFrame = 2, endFrame = 6 }, pan = 0 }))
  local pcm = loopMixer:render(120)
  Assert.equal(leftAt(pcm, 16), 100, "the pre-loop region plays sample 1 first")
  Assert.equal(leftAt(pcm, 32), 200, "the pre-loop region plays sample 2")
  Assert.equal(leftAt(pcm, 48), 300, "the loop window starts at sample 3")
  Assert.equal(leftAt(pcm, 96), 600, "the window plays sample 6 at its end")
  Assert.equal(leftAt(pcm, 97), 300, "the window repeats from sample 3")

  local oneShot = newMixer(DS_RATE)
  oneShot:noteOn(spec({ baseTimer = 16, loopEnabled = false, pan = 0 }))
  local shot = oneShot:render(140)
  Assert.equal(leftAt(shot, 128), 800, "the one-shot wave plays its window")
  Assert.equal(leftAt(shot, 129), 0, "the one-shot stops at the window end")

  local held = newMixer()
  local pcm2048 = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  local handle = held:noteOn(spec({ pcm = pcm2048, pan = 0 })) --[[@as { channel: integer, generation: integer }]]
  local before = held:render(12)
  Assert.equal(leftAt(before, 12), 2048, "the looping voice holds")
  held:noteOff(handle)
  local after = {}
  held:renderInto(after, 500)
  -- The release's first step fires at the explicit control step (frame 500,
  -- release 127's register 0x306) and the second step (frame 750) stops the
  -- voice -- the mixer no longer self-steps inside rendering.
  Assert.equal(leftAt(after, 500), 2048, "the voice keeps sounding until the explicit control step")
  held:controlStep()
  held:renderInto(after, 250)
  Assert.equal(leftAt(after, 501), 6, "release 127 reaches register 0x306 at the control step")
  Assert.equal(leftAt(after, 750), 6, "the first release register holds through the next interval")
  held:controlStep()
  held:renderInto(after, 250)
  Assert.equal(leftAt(after, 751), 0, "release 127 stops the voice on the following control step")
end

function T.mixing_sums_saturates_and_rendering_is_chunk_independent()
  local DS_RATE = 16756991
  local mixer = newMixer(DS_RATE)
  local loud = { 30000, -30000, 30000, -30000, 30000, -30000, 30000, -30000 }
  mixer:noteOn(spec({ pcm = loud, pan = 0 }))
  mixer:noteOn(spec({ pcm = loud, pan = 0 }))
  local pcm = mixer:render(24018)
  Assert.equal(leftAt(pcm, 8006), 32767, "two sample-1 voices saturate at +32767")
  Assert.equal(leftAt(pcm, 16012), -32768, "two sample-2 voices saturate at -32768")
  Assert.equal(leftAt(pcm, 24018), 32767, "the mix keeps saturating at the int16 bounds")

  local function playChunked(chunks)
    local m = newMixer()
    m:noteOn(spec({
      pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 },
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

-- The batched render contract: renderInto(output, frames) appends a span
-- of interleaved stereo PCM to a caller-owned table -- no fresh result table
-- per call, so a span render reuses the caller's buffer -- and is
-- byte-identical to the per-call render pattern, chunk independent, and
-- stable across control-step boundaries. render(frames) stays as the thin
-- per-call wrapper over the same span machinery.
function T.render_into_appends_spans_byte_identical_to_render()
  local wave = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  local function viaRenderInto(chunks)
    local mixer = newMixer()
    mixer:noteOn(spec({ pcm = wave, pan = 0, envelope = { attack = 0, decay = 127, sustain = 127, release = 127 } }))
    local out = {}
    for _, frames in ipairs(chunks) do
      mixer:renderInto(out, frames)
    end
    return out
  end
  local function viaRender(chunks)
    local mixer = newMixer()
    mixer:noteOn(spec({ pcm = wave, pan = 0, envelope = { attack = 0, decay = 127, sustain = 127, release = 127 } }))
    local out = {}
    for _, frames in ipairs(chunks) do
      local pcm = mixer:render(frames)
      for i = 1, #pcm do
        out[#out + 1] = pcm[i]
      end
    end
    return out
  end
  local whole = viaRenderInto({ 400 })
  Assert.deepEqual(
    whole,
    viaRender({ 400 }),
    "a span rendered into a caller buffer is byte-identical to the per-call render pattern"
  )
  Assert.deepEqual(whole, viaRenderInto({ 200, 200 }), "renderInto spans are chunk independent")
  Assert.deepEqual(
    whole,
    viaRenderInto({ 249, 151 }),
    "a renderInto split across a control-step boundary is byte-identical"
  )
end

-- The mixer is the authoritative owner of voice liveness. isVoiceAlive
-- (handle) is true from noteOn through the release ring-out and false once
-- the mixer removes the voice -- a natural one-shot death, a generation
-- mismatch, and an empty channel all answer false. The sequencer prunes its
-- voice collections with this query instead of predicting the death moment.
function T.is_voice_alive_tracks_liveness_until_removal()
  local mixer = newMixer()
  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  local handle = mixer:noteOn(spec({ pcm = pcm, pan = 0 })) --[[@as { channel: integer, generation: integer }]]
  Assert.isTrue(mixer:isVoiceAlive(handle), "a fresh voice is alive")
  mixer:render(4)
  Assert.isTrue(mixer:isVoiceAlive(handle), "a sounding voice stays alive")
  mixer:noteOff(handle)
  Assert.isTrue(mixer:isVoiceAlive(handle), "a voice in release stays alive until the mixer removes it")
  mixer:render(250)
  mixer:controlStep() -- release 127 step 1: register 0x306
  Assert.isTrue(mixer:isVoiceAlive(handle), "release 127 is still alive after its first release step")
  mixer:render(250)
  mixer:controlStep() -- release 127 step 2: vol <= -723 removes the voice
  Assert.isFalse(mixer:isVoiceAlive(handle), "the release completed and the voice was removed")

  local oneShot = newMixer()
  local shot = oneShot:noteOn(spec({ loopEnabled = false, pan = 0, baseTimer = 16 })) --[[@as { channel: integer, generation: integer }]]
  Assert.isTrue(oneShot:isVoiceAlive(shot), "the one-shot voice is alive before its window ends")
  oneShot:render(12)
  Assert.isFalse(oneShot:isVoiceAlive(shot), "a one-shot voice is dead once the window ended")
  Assert.isFalse(
    oneShot:isVoiceAlive({ channel = shot.channel, generation = shot.generation + 1 }),
    "a generation mismatch is not alive"
  )
  Assert.isFalse(oneShot:isVoiceAlive({ channel = 15, generation = 0 }), "an empty channel is not alive")
end

-- Release death is computed per control step from the current register
-- inputs (SND_exChannel.c ExChannelMain: the pre-register dB sum crossing
-- SND_VOL_DB_MIN), never from a noteOff-time count. A control value pushed
-- during the release -- here track volume 0 -- reaches the volume sum at
-- the next control step and stops the voice the same step; the voice cannot
-- keep ringing out a count precomputed from the louder noteOff-time inputs.
-- The step is an explicit mixer controlStep (the external scheduler's
-- cadence), so the test renders the first interval, steps, then pushes the
-- mute before the next step.
function T.release_death_follows_the_current_volume_not_a_precomputed_count()
  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  local mixer = newMixer()
  local handle = mixer:noteOn(spec({
    pcm = pcm,
    pan = 0,
    envelope = { attack = 127, decay = 127, sustain = 127, release = 100 },
  })) --[[@as { channel: integer, generation: integer }]]
  local head = {}
  mixer:renderInto(head, 250)
  mixer:controlStep() -- the note's step 2
  mixer:noteOff(handle)
  mixer:updateVoice(handle, { trackVolume = 0 })
  local tail = {}
  mixer:renderInto(tail, 250)
  Assert.equal(leftAt(tail, 250), 2048, "the voice still holds the release at full volume until the step")
  mixer:controlStep() -- track volume 0 reaches the sum: vol <= -723 stops the voice here
  mixer:renderInto(tail, 250)
  Assert.equal(leftAt(tail, 251), 0, "track volume 0 stops the release at the next control step")
  Assert.equal(leftAt(tail, 500), 0, "the voice never rings on the noteOff-time volume")
end

-- noteOff(handle, releaseOverride) sets the channel release before
-- entering release: nil keeps the voice's instrument release; an integer
-- 0..127 replaces the release byte (through CalcDecayCoeff). Override 100
-- on a release-127 voice rings 314 steps and stops at the vol <= -723
-- threshold (register 0x301 -> 1 through the last sounding step); override
-- 127 on a slow release-20 voice stops in two steps like release 127. The
-- steps are explicit mixer controlSteps at the 250-frame interval
-- boundaries (the external scheduler's cadence); the noteOff here lands
-- before any control step, so the release's first step fires at the first
-- interval boundary (frame 250).
function T.release_override_applies_the_coefficient_before_release()
  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  local function driveBlock(mixer, out, frames)
    local remaining = frames
    while remaining > 0 do
      local span = math.min(remaining, 250)
      mixer:renderInto(out, span)
      remaining = remaining - span
      if remaining > 0 then
        mixer:controlStep()
      end
    end
  end
  local function run(releaseByte, override, frames)
    local mixer = newMixer()
    local handle = mixer:noteOn(spec({
      pcm = pcm,
      pan = 0,
      envelope = { attack = 127, decay = 127, sustain = 127, release = releaseByte },
    })) --[[@as { channel: integer, generation: integer }]]
    mixer:noteOff(handle, override)
    local out = {}
    driveBlock(mixer, out, frames)
    return out
  end
  local slow = run(127, 100, 78501)
  Assert.equal(leftAt(slow, 78500), 1, "override 100 rings through release step 314 (register 0x301)")
  Assert.equal(leftAt(slow, 78501), 0, "override 100 stops at release step 314 (vol <= -723)")
  local fast = run(127, nil, 801)
  Assert.equal(leftAt(fast, 251), 6, "nil keeps release 127 (register 0x306 at step 1)")
  Assert.equal(leftAt(fast, 501), 0, "nil keeps release 127 (the two-step stop)")
  local forced = run(20, 127, 801)
  Assert.equal(leftAt(forced, 251), 6, "override 127 replaces the instrument release 20 (register 0x306)")
  Assert.equal(leftAt(forced, 501), 0, "override 127 stops on the second release step")
end

-- The release override contract is nil or an integer 0..127; anything else
-- is a programming fault at the mixer boundary, and 0 stays a valid slow
-- release.
function T.release_override_rejects_out_of_range_values()
  local mixer = newMixer()
  local handle = mixer:noteOn(spec({ pan = 0 })) --[[@as { channel: integer, generation: integer }]]
  Assert.throws(function()
    mixer:noteOff(handle, 128)
  end, "a release override above 127 is rejected")
  Assert.throws(function()
    mixer:noteOff(handle, -1)
  end, "a negative release override is rejected")
  Assert.throws(function()
    mixer:noteOff(handle, 1.5)
  end, "a non-integer release override is rejected")
  mixer:noteOff(handle, 0)
  mixer:render(1)
end

-- The 192 Hz cadence is owned by the external scheduler (the C03 contract),
-- not by the mixer: at the production 32768 Hz rate the scheduler's exact
-- integer accumulator (phase += 192 per output frame, one interval when it
-- reaches the output rate) places the interval boundaries at 171, 342, 512,
-- 683, ... -- never every floor(32768/192) = 170 frames. This test proves
-- the mixer honors that external cadence: driving one explicit controlStep
-- at each exact boundary reproduces the known attack-100 register vectors
-- 0x30D/0x360/0x250/0x20E (13/96/320/664) on exactly those boundary frames,
-- with the step's registers applying from the frame after the boundary.
-- noteOn synchronizes the initial registers (frame 1 reads the initial
-- register); each explicit controlStep advances elapsed state.
function T.control_steps_follow_the_external_boundary_cadence_at_32768_hz()
  local mixer = newMixer(32768)
  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  mixer:noteOn(spec({ pcm = pcm, pan = 0, envelope = { attack = 100, decay = 127, sustain = 127, release = 127 } }))
  local out = {}
  local prev = 0
  local boundaries = { 171, 342, 512, 683, 854 }
  for _, boundary in ipairs(boundaries) do
    mixer:renderInto(out, boundary - prev)
    prev = boundary
    mixer:controlStep()
  end
  mixer:renderInto(out, 1)
  Assert.equal(leftAt(out, 1), 13, "noteOn synchronizes the initial register 0x30D")
  Assert.equal(leftAt(out, 171), 13, "step 2 fires at the end of frame 171, not at 170 (register 0x30D)")
  Assert.equal(leftAt(out, 172), 96, "step 2 registers apply from frame 172 (register 0x360)")
  Assert.equal(leftAt(out, 341), 96, "frame 341 still reads the step-2 register (0x360)")
  Assert.equal(leftAt(out, 342), 96, "frame 342 is the last step-2 frame (register 0x360)")
  Assert.equal(leftAt(out, 343), 320, "step 3 registers apply from frame 343 (register 0x250)")
  Assert.equal(leftAt(out, 512), 320, "step 4 fires at frame 512 (the 171+171+170 accumulation)")
  Assert.equal(leftAt(out, 513), 664, "step 4 registers apply from frame 513 (register 0x20E)")
  Assert.equal(leftAt(out, 683), 664, "step 5 fires at frame 683 (register 0x20E)")
  Assert.equal(leftAt(out, 684), 1040, "step 5 registers apply from frame 684")
  Assert.equal(leftAt(out, 854), 1040, "step 6 fires at frame 854")
  Assert.equal(leftAt(out, 855), 1360, "step 6 registers apply from frame 855")
end

-- One explicit controlStep is exactly one envelope advance: over a long run
-- at the production 32768 Hz rate, 314 release steps of a release-100 voice
-- (295 units per step) stop it at the vol <= -723 threshold at the control
-- step after boundary frame ceil(32768*314/192) = 53590, with the
-- step-313/314 register 0x301 (gain 1/2048 -> sample 1) sounding through
-- that boundary frame and silence from 53591 -- proving the 192 steps per
-- second come from the scheduler's exact 171/171/170 boundaries, not a
-- floored 170-frame period (which would stop the voice at 53380, ~210
-- frames early). The mixer contract is that each explicit controlStep
-- advances the envelope exactly once, whatever the scheduler's frame
-- spacing.
function T.exactly_one_envelope_advance_per_external_control_step_at_32768_hz()
  local mixer = newMixer(32768)
  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  local handle = mixer:noteOn(spec({
    pcm = pcm,
    pan = 0,
    envelope = { attack = 127, decay = 127, sustain = 127, release = 100 },
  })) --[[@as { channel: integer, generation: integer }]]
  mixer:noteOff(handle)
  local out = {}
  local remaining = 53600
  local prev = 0
  local boundaries = {}
  local phase = 0
  for frame = 1, 53600 do
    phase = phase + 192
    if phase >= 32768 then
      phase = phase - 32768
      boundaries[#boundaries + 1] = frame
    end
  end
  for _, boundary in ipairs(boundaries) do
    mixer:renderInto(out, boundary - prev)
    prev = boundary
    mixer:controlStep()
  end
  -- Render a short tail past the last boundary so the death frame is
  -- observable in the output.
  mixer:renderInto(out, 10)
  Assert.equal(leftAt(out, 53400), 1, "the release still sounds past the floored-period death frame 53380")
  Assert.equal(leftAt(out, 53590), 1, "the last sounding frame is the 314th release step's boundary frame")
  Assert.equal(leftAt(out, 53591), 0, "the voice stops the frame after step 314")
end

-- The phase accumulator is absolute mixer frame state, so chunking
-- the same total frames differently at 32768 Hz -- including splits across
-- the alternating 170/171 boundaries -- produces byte-identical PCM.
function T.chunking_is_independent_at_32768_hz()
  local function playChunked(chunks)
    local mixer = newMixer(32768)
    mixer:noteOn(spec({
      pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 },
      pan = 0,
      envelope = { attack = 0, decay = 127, sustain = 127, release = 127 },
    }))
    local out = {}
    for _, frames in ipairs(chunks) do
      local part = mixer:render(frames)
      for i = 1, #part do
        out[#out + 1] = part[i]
      end
    end
    return out
  end
  local whole = playChunked({ 400 })
  Assert.deepEqual(whole, playChunked({ 200, 200 }), "chunk boundaries do not move the control steps")
  Assert.deepEqual(whole, playChunked({ 171, 170, 59 }), "a 171/170 split is byte-identical")
  Assert.deepEqual(whole, playChunked({ 100, 100, 100, 100 }), "small chunks are byte-identical")
end

-- PCM playback phase derives from the DS sound clock and the
-- calculated channel timer (DS_SOUND_CLOCK / timer / outputRate), never
-- from a source sample-rate header: the voice spec carries no sampleRate.
-- At a DS-clock-rate mixer (16756991 Hz) the base timer 8006 advances the
-- read exactly one sample per 8006 frames (frame 8006 reads the first wave
-- sample, frame 8007 the second); at the production 32768 Hz rate a
-- 512-base-timer wave (clock/512 ~= 32728 Hz) drifts the read to sample 9
-- by frame 32769.
function T.sample_voices_play_from_the_ds_clock_and_timer_without_a_source_rate()
  local function rateSpec(baseTimer)
    -- The 16-sample wave carries the 16-frame loop window; the production
    -- rate reads sample 9 at frame 32769, so the wave must cover it.
    return spec({ pcm = WAVE16, pan = 0, baseTimer = baseTimer, loop = { startFrame = 0, endFrame = 16 } })
  end
  local dsRate = newMixer(16756991)
  dsRate:noteOn(rateSpec(8006))
  local out = dsRate:render(8020)
  Assert.equal(leftAt(out, 8006), 100, "at the DS clock the wave advances one sample per 8006 frames (sample 1)")
  Assert.equal(leftAt(out, 8007), 200, "frame 8007 reads the second sample")

  local production = newMixer(32768)
  production:noteOn(rateSpec(512))
  local prod = production:render(32769)
  Assert.equal(leftAt(prod, 32769), 900, "at 32768 Hz the clock-derived rate reads sample 9 by frame 32769")
end

-- Duty index 7 is the DS special all-LOW pattern (GBATEK "PSG
-- rectangular wave"): the 8-step cycle never goes HIGH, unlike duty 6,
-- which is one LOW step then seven HIGH steps.
function T.square_duty_seven_is_all_low()
  local mixer = newMixer(16756991)
  mixer:noteOn(spec({ generator = { kind = "square", duty = 7 }, key = 60, channelMask = 0x3F00, pan = 0 }))
  local out = mixer:render(8005)
  for frame = 1, 8005 do
    Assert.equal(leftAt(out, frame), -32767, "duty 7 stays LOW through the full cycle at frame " .. frame)
  end
end

-- The mixer consumes the discrete integer duty index 0..7 directly and
-- renders the (7-d) LOW / (d+1) HIGH 8-step grid at the masked timer;
-- floats are a programming fault, not a duty to convert back to an index.
function T.square_duty_is_consumed_as_the_integer_index()
  local DS_RATE = 16756991
  local six = newMixer(DS_RATE)
  six:noteOn(spec({ generator = { kind = "square", duty = 6 }, key = 60, channelMask = 0x3F00, pan = 0 }))
  local out = six:render(64040)
  Assert.equal(leftAt(out, 8004), -32767, "duty 6 starts with one LOW step (7-6, masked timer 8004)")
  Assert.equal(leftAt(out, 8005), 32767, "duty 6 turns HIGH for seven steps")
  Assert.equal(leftAt(out, 64032), 32767, "duty 6 stays HIGH through step 7 of the cycle")
  Assert.equal(leftAt(out, 64033), -32767, "duty 6 restarts LOW on the next cycle")

  local function rejects(duty)
    local mixer = newMixer(DS_RATE)
    Assert.throws(function()
      mixer:noteOn(spec({ generator = { kind = "square", duty = duty }, key = 60, channelMask = 0x3F00 }))
    end, "square duty " .. tostring(duty) .. " is not an integer index 0..7")
  end
  -- 1.0 is the integer 1 in LuaJIT (no float/integer value distinction), so
  -- an integral float cannot be told apart from the valid duty 1; the
  -- non-integral float pins the float rejection instead.
  rejects(0.5)
  rejects(1.5)
  rejects(8)
  rejects(-1)
end

-- The external control cadence (the C03 contract): renderInto is a pure PCM
-- span renderer and must never advance the 192 Hz control state on its own --
-- no envelope step, no sweep/LFO advance, no pending-value application. One
-- explicit controlStep() advances the channel-control state exactly once.
-- Proof without a phase spy: an instant-attack (attack 127) constant voice
-- reaches the full initial register on noteOn and holds it while rendering
-- across what used to be control boundaries, so the register sampled after
-- 500 frames must be unchanged; only the explicit control step can change it.
function T.renderInto_never_runs_a_control_step_without_an_explicit_call()
  local pcm = { 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048 }
  local function run(chunks)
    local mixer = newMixer()
    local handle = mixer:noteOn(spec({
      pcm = pcm,
      pan = 0,
      envelope = { attack = 127, decay = 127, sustain = 127, release = 127 },
    })) --[[@as { channel: integer, generation: integer }]]
    local out = {}
    for _, frames in ipairs(chunks) do
      mixer:renderInto(out, frames)
    end
    return mixer, handle, out
  end
  local mixer, handle, out = run({ 250, 250 })
  Assert.equal(leftAt(out, 250), 2048, "the voice holds the full register at the first former boundary")
  Assert.equal(leftAt(out, 500), 2048, "rendering across the 192 Hz boundary changes nothing")
  -- A control-value push stays queued (dirty) through pure rendering and is
  -- only applied by the explicit control step.
  mixer:updateVoice(handle, { trackVolume = 64 })
  local tail = {}
  mixer:renderInto(tail, 250)
  Assert.equal(leftAt(tail, 250), 2048, "a queued control value does not apply during pure rendering")
  mixer:controlStep()
  mixer:renderInto(tail, 1)
  Assert.equal(leftAt(tail, 251), 520, "the explicit control step applies the queued value (track volume 64)")
end

-- The sweep counter has exactly one owner per auto flag
-- (SND_seq.c TrackStepTicks vs SND_ExChannelMain): a non-auto-sweep voice
-- advances its counter only through the sequence-owned
-- `advanceTrackTick(handle)` -- once per sequence tick, capped at the sweep
-- length -- and a controlStep must never advance it; an auto-sweep voice
-- advances only at control steps and never through `advanceTrackTick`. A
-- stale/dead handle is a no-op like the other handle operations.
local function sweepMixer(autoSweep)
  local mixer = newMixer(nil, false)
  local handle = mixer:noteOn(spec({
    pcm = WAVE16,
    baseTimer = 512,
    loop = { startFrame = 0, endFrame = 16 },
    sweepPitch = 768,
    sweepLength = 4,
    autoSweep = autoSweep,
    pan = 0,
  })) --[[@as { channel: integer, generation: integer }]]
  return mixer, handle
end

function T.advance_track_tick_never_releases_and_is_a_no_op_for_a_stale_handle()
  local mixer, handle = sweepMixer(false)
  local out = {}
  mixer:renderInto(out, 250)
  mixer:advanceTrackTick(handle)
  Assert.isTrue(mixer:isVoiceAlive(handle), "the track tick advances the sweep, never the envelope or release")
  -- A stale handle (a dead voice) is a harmless no-op.
  mixer:noteOff(handle)
  local tail = {}
  mixer:renderInto(tail, 250)
  mixer:controlStep()
  mixer:controlStep()
  Assert.isFalse(mixer:isVoiceAlive(handle), "the release completed and removed the voice")
  mixer:advanceTrackTick(handle)
  mixer:advanceTrackTick({ channel = handle.channel, generation = handle.generation + 1 })
end

function T.non_auto_sweep_advances_only_on_sequence_ticks_and_auto_sweep_only_on_control_steps()
  -- Non-auto: four explicit advanceTrackTick calls move the counter to the
  -- cap; pure rendering and control steps must not move it.
  local manual, h = sweepMixer(false)
  local manualOut = {}
  manual:renderInto(manualOut, 250)
  manual:advanceTrackTick(h)
  manual:controlStep()
  manual:renderInto(manualOut, 250)
  manual:advanceTrackTick(h)
  manual:advanceTrackTick(h)
  manual:advanceTrackTick(h)
  manual:advanceTrackTick(h) -- past the length: capped at sweepLength 4
  manual:controlStep()
  manual:controlStep()
  manual:controlStep()
  manual:renderInto(manualOut, 750)
  Assert.equal(
    leftAt(manualOut, 1250),
    300,
    "the capped counter holds the final contribution: at counter 4 the sweep has run out (timer 512) and the read lands on sample 3"
  )
  -- Auto: each control step advances the counter; advanceTrackTick must
  -- never move it. With base timer 512 and sweepLength 4 the contribution
  -- falls to zero at the step after the fourth advance (the existing
  -- sweep_ramps pins the PCM register rows).
  local auto, ha = sweepMixer(true)
  auto:advanceTrackTick(ha) -- must be a no-op for the auto voice
  local autoOut = {}
  auto:renderInto(autoOut, 250)
  auto:controlStep()
  auto:advanceTrackTick(ha) -- must be a no-op
  auto:renderInto(autoOut, 250)
  auto:controlStep()
  auto:renderInto(autoOut, 250)
  auto:controlStep()
  auto:renderInto(autoOut, 250)
  auto:controlStep()
  auto:renderInto(autoOut, 250)
  auto:controlStep()
  auto:renderInto(autoOut, 1)
  Assert.equal(leftAt(autoOut, 501), 500, "auto step 2 lands the doubled-rate timer (the auto counter advanced)")
  Assert.equal(leftAt(autoOut, 1251), 1100, "the auto sweep completed at the capped counter")
end

return { tests = T }
