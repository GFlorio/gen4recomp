-- VoiceMixer contract: a deterministic 16-voice DS-like mixer. Sixteen
-- channels; sample voices allocate any channel, square only channels 8-13,
-- noise only 14-15 (GBATEK "NDS Sound" hardware chapter: format 3 is
-- PSG-only on those ranges); allocation and priority stealing operate inside
-- the intersection of the generator range and the player's channelMask.
-- Sample voices render nearest-sample (no interpolation), loop
-- inside their metadata loop window, and end only on noteOff. Square duty
-- cycles are 8 samples starting at LOW (GBATEK: HIGH=(N+1)*12.5%, period 8,
-- duty starts at the LOW period); noise is the GBATEK 15-bit LFSR
-- (X=X SHR 1; carry -> LOW and X XOR 6000h, else HIGH; init 7FFFh). The
-- envelope is a project-defined linear model over the frozen 0..127 ADSR
-- bytes (attack/decay/release ramp over (127-v)*8 frames, 127 = instant;
-- sustain is a level; 127 = stay at max). Gain = velocity/127 * volume/127 *
-- expression/127; pan 0 = left only, 127 = right only, 64 = equal both.
-- Mixing sums and saturates at +-32767/+-32768. Commands issued between
-- renders apply at the start of the next render. Output is interleaved
-- stereo int16 (2*frames entries).

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")

local T = {}

local SAMPLE_RATE = 48000

-- Distinct small-amplitude waves so voice sums never clip and every voice is
-- identifiable in the mix.
local WAVE_A = { 100, 200, 300, 400, 500, 600, 700, 800 }
local CONST = { 5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000 }

local function wave(n)
  local w = {}
  for i = 1, 8 do
    w[i] = (100 + n * 10) * i
  end
  return w
end

local function newMixer()
  return VoiceMixer.new({ sampleRate = SAMPLE_RATE })
end

local function spec(overrides)
  local s = {
    generator = { kind = "sample", sample = AudioFixture.key(1) },
    sampleRate = SAMPLE_RATE,
    pcm = AudioFixture.pcm16le(WAVE_A),
    loop = { startFrame = 0, endFrame = 8 },
    key = 60,
    rootKey = 60,
    velocity = 127,
    volume = 127,
    expression = 127,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = 0,
    channelPriority = 64,
    playerPriority = 64,
    channelMask = 0xFFFF,
  }
  for key, value in pairs(overrides or {}) do
    s[key] = value
  end
  return s
end

-- Builds the interleaved stereo array a voice renders as: the left channel
-- carries `left` (per-frame samples), the right channel stays zero.
local function stereo(left)
  local out = {}
  for i = 1, #left do
    out[#out + 1] = left[i]
    out[#out + 1] = 0
  end
  return out
end

local function leftAt(pcm, frame)
  return pcm[frame * 2 - 1]
end

local function rightAt(pcm, frame)
  return pcm[frame * 2]
end

local function frameRange(pcm, first, last, channel)
  local out = {}
  for frame = first, last do
    out[#out + 1] = pcm[frame * 2 - (2 - (channel or 1))]
  end
  return out
end

function T.renders_silence_without_voices()
  local mixer = newMixer()
  local pcm = mixer:render(32)
  Assert.equal(#pcm, 64)
  for i = 1, 64 do
    Assert.equal(pcm[i], 0, "no voices, no sound")
  end
end

function T.sample_voice_renders_the_wave_at_unity_pitch()
  local mixer = newMixer()
  local channel = mixer:noteOn(spec())
  Assert.equal(channel, 0, "the first sample voice takes channel 0")
  local pcm = mixer:render(8)
  Assert.deepEqual(pcm, stereo(WAVE_A), "wave sample n at frame n")
  Assert.deepEqual(frameRange(pcm, 1, 8, 2), { 0, 0, 0, 0, 0, 0, 0, 0 }, "pan 0 keeps the right channel silent")
end

function T.sample_voice_pitch_follows_the_key_in_semitones()
  local function renderAt(key, frames)
    local mixer = newMixer()
    mixer:noteOn(spec({ key = key }))
    return frameRange(mixer:render(frames), 1, frames, 1)
  end
  Assert.deepEqual(renderAt(72, 8), { 100, 300, 500, 700, 100, 300, 500, 700 }, "an octave up reads every other sample")
  Assert.deepEqual(
    renderAt(48, 8),
    { 100, 100, 200, 200, 300, 300, 400, 400 },
    "an octave down reads each sample twice"
  )
end

function T.sample_voice_loops_inside_its_loop_window()
  local mixer = newMixer()
  mixer:noteOn(spec({ loop = { startFrame = 2, endFrame = 6 } }))
  local pcm = mixer:render(8)
  Assert.deepEqual(
    frameRange(pcm, 1, 8, 1),
    { 300, 400, 500, 600, 300, 400, 500, 600 },
    "frames outside the window are never played"
  )
end

function T.sample_voice_loops_until_released()
  local mixer = newMixer()
  local channel = mixer:noteOn(spec())
  local pcm = mixer:render(12)
  Assert.deepEqual(
    frameRange(pcm, 1, 12, 1),
    { 100, 200, 300, 400, 500, 600, 700, 800, 100, 200, 300, 400 },
    "a full loop repeats past the wave end"
  )
  mixer:noteOff(channel)
  local after = mixer:render(8)
  for i = 1, 8 do
    Assert.equal(leftAt(after, i), 0, "release 127 ends the voice immediately")
  end
end

function T.square_voice_renders_gbatek_duty_cycles()
  local function squareAt(duty, key, frames)
    local mixer = newMixer()
    mixer:noteOn(spec({ generator = { kind = "square", duty = duty }, key = key }))
    return frameRange(mixer:render(frames), 1, frames, 1)
  end
  Assert.deepEqual(squareAt(0.5, 60, 16), {
    -32767,
    -32767,
    -32767,
    -32767,
    32767,
    32767,
    32767,
    32767,
    -32767,
    -32767,
    -32767,
    -32767,
    32767,
    32767,
    32767,
    32767,
  }, "duty 0.5 is 4 LOW then 4 HIGH, starting at LOW, at +-7FFF")
  Assert.deepEqual(
    squareAt(0.25, 60, 8),
    { -32767, -32767, -32767, -32767, -32767, -32767, 32767, 32767 },
    "duty 0.25 is 6 LOW then 2 HIGH"
  )
  Assert.deepEqual(
    squareAt(0.5, 72, 8),
    { -32767, -32767, 32767, 32767, -32767, -32767, 32767, 32767 },
    "an octave up halves the 8-sample period"
  )
end

function T.noise_voice_renders_the_deterministic_lfsr()
  local mixer = newMixer()
  mixer:noteOn(spec({ generator = { kind = "noise" } }))
  local pcm = mixer:render(16)
  Assert.deepEqual(frameRange(pcm, 1, 16, 1), {
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    -32767,
    32767,
    32767,
  }, "the GBATEK LFSR from X=7FFFh: 14 LOWs then 2 HIGHs")
end

function T.pan_routes_voices_across_channels()
  local function renderAt(pan)
    local mixer = newMixer()
    mixer:noteOn(spec({ pan = pan }))
    return mixer:render(8)
  end
  local left = renderAt(0)
  Assert.deepEqual(frameRange(left, 1, 8, 2), { 0, 0, 0, 0, 0, 0, 0, 0 }, "pan 0 keeps the right channel silent")
  local right = renderAt(127)
  Assert.deepEqual(frameRange(right, 1, 8, 1), { 0, 0, 0, 0, 0, 0, 0, 0 }, "pan 127 keeps the left channel silent")
  Assert.deepEqual(frameRange(right, 1, 8, 2), WAVE_A, "pan 127 renders the full wave on the right")
  local center = renderAt(64)
  for frame = 1, 8 do
    Assert.equal(leftAt(center, frame), rightAt(center, frame), "pan 64 is equal on both channels")
    Assert.isTrue(leftAt(center, frame) > 0, "pan 64 is audible")
  end
end

function T.velocity_volume_and_expression_scale_the_gain()
  local function renderWith(overrides)
    local mixer = newMixer()
    mixer:noteOn(spec(overrides))
    return frameRange(mixer:render(8), 1, 8, 1)
  end
  local full = renderWith({ pcm = AudioFixture.pcm16le(CONST) })
  Assert.deepEqual(full, CONST, "all knobs at 127 is unity gain")
  local velocity = renderWith({ pcm = AudioFixture.pcm16le(CONST), velocity = 64 })
  Assert.equal(velocity[1], math.floor(5000 * 64 / 127 + 0.5), "velocity scales linearly, rounded")
  local volume = renderWith({ pcm = AudioFixture.pcm16le(CONST), volume = 64 })
  Assert.equal(volume[1], math.floor(5000 * 64 / 127 + 0.5), "volume scales linearly, rounded")
  local expression = renderWith({ pcm = AudioFixture.pcm16le(CONST), expression = 64 })
  Assert.equal(expression[1], math.floor(5000 * 64 / 127 + 0.5), "expression scales linearly, rounded")
end

function T.envelope_sustain_holds_and_release_ends_the_voice()
  local mixer = newMixer()
  local channel = mixer:noteOn(spec({ pcm = AudioFixture.pcm16le(CONST) }))
  local held = mixer:render(16)
  for frame = 1, 16 do
    Assert.equal(leftAt(held, frame), 5000, "sustain 127 holds the full level")
  end
  mixer:noteOff(channel)
  local released = mixer:render(8)
  for frame = 1, 8 do
    Assert.equal(leftAt(released, frame), 0, "release 127 is instant")
  end

  local mixer2 = newMixer()
  local channel2 = mixer2:noteOn(
    spec({ pcm = AudioFixture.pcm16le(CONST), envelope = { attack = 127, decay = 0, sustain = 127, release = 0 } })
  )
  mixer2:render(8)
  mixer2:noteOff(channel2)
  local fading = mixer2:render(1017)
  Assert.equal(leftAt(fading, 1), 5000, "release starts at the held level")
  Assert.isTrue(leftAt(fading, 2) < leftAt(fading, 1), "release ramps down")
  Assert.equal(
    leftAt(fading, 509),
    math.floor(5000 * 0.5 + 0.5),
    "release 0 reaches half level halfway through its 1016-frame ramp"
  )
  Assert.equal(leftAt(fading, 1017), 0, "release 0 ends the voice after its ramp")
end

function T.envelope_attack_ramps_and_sustain_zero_decays_to_silence()
  local mixer = newMixer()
  mixer:noteOn(
    spec({ pcm = AudioFixture.pcm16le(CONST), envelope = { attack = 0, decay = 0, sustain = 0, release = 127 } })
  )
  local pcm = mixer:render(4096)
  Assert.equal(leftAt(pcm, 1), 0, "a slow attack starts at silence")
  Assert.isTrue(leftAt(pcm, 2) > leftAt(pcm, 1), "the attack ramps up")
  Assert.equal(
    leftAt(pcm, 509),
    math.floor(5000 * 0.5 + 0.5),
    "attack 0 reaches half level halfway through its 1016-frame ramp"
  )
  Assert.equal(leftAt(pcm, 1017), 5000, "the attack completes at full level")
  Assert.equal(leftAt(pcm, 1525), math.floor(5000 * 0.5 + 0.5), "decay to sustain level 0 halfways through its ramp")
  Assert.equal(leftAt(pcm, 2033), 0, "sustain 0 decays to silence while held")
  Assert.equal(leftAt(pcm, 4096), 0, "the voice stays silent")
end

function T.sixteen_voice_limit_with_priority_stealing()
  local mixer = newMixer()
  local waveA = spec()
  for i = 1, 16 do
    local channel = mixer:noteOn(waveA)
    Assert.notNil(channel, "sixteen voices fit")
  end
  local sixteen = mixer:render(8)
  local expected = {}
  for i = 1, 8 do
    expected[i] = WAVE_A[i] * 16
  end
  Assert.deepEqual(frameRange(sixteen, 1, 8, 1), expected, "all sixteen voices mix")

  local waveB = spec({ pcm = AudioFixture.pcm16le(wave(2)), channelPriority = 100 })
  local stolen = mixer:noteOn(waveB)
  Assert.notNil(stolen, "the seventeenth note steals a channel instead of being dropped")
  local mixed = mixer:render(8)
  local expectedMixed = {}
  for i = 1, 8 do
    expectedMixed[i] = WAVE_A[i] * 15 + wave(2)[i]
  end
  Assert.deepEqual(frameRange(mixed, 1, 8, 1), expectedMixed, "the lowest-priority voice was replaced")
  mixer:noteOff(stolen)
  local after = mixer:render(8)
  local expectedAfter = {}
  for i = 1, 8 do
    expectedAfter[i] = WAVE_A[i] * 15
  end
  Assert.deepEqual(frameRange(after, 1, 8, 1), expectedAfter, "the stolen channel now carries the new voice")
end

function T.same_priority_stealing_takes_the_oldest_voice()
  local mixer = newMixer()
  local waveA = spec()
  local waveB = spec({ pcm = AudioFixture.pcm16le(wave(2)) })
  local waveC = spec({ pcm = AudioFixture.pcm16le(wave(3)) })
  for i = 1, 16 do
    mixer:noteOn(waveA)
  end
  mixer:noteOn(waveB)
  mixer:noteOn(waveC)
  local pcm = mixer:render(8)
  local expected = {}
  for i = 1, 8 do
    expected[i] = WAVE_A[i] * 14 + wave(2)[i] + wave(3)[i]
  end
  Assert.deepEqual(frameRange(pcm, 1, 8, 1), expected, "equal priorities evict the two oldest voices")
end

function T.player_priority_dominates_channel_priority_when_stealing()
  local mixer = newMixer()
  local waveA = spec()
  local waveB = spec({ pcm = AudioFixture.pcm16le(wave(2)), playerPriority = 16, channelPriority = 1 })
  for i = 1, 15 do
    mixer:noteOn(waveA)
  end
  mixer:noteOn(waveB)
  mixer:noteOn(spec({ pcm = AudioFixture.pcm16le(wave(3)), playerPriority = 64, channelPriority = 64 }))
  local pcm = mixer:render(8)
  local expected = {}
  for i = 1, 8 do
    expected[i] = WAVE_A[i] * 15 + wave(3)[i]
  end
  Assert.deepEqual(
    frameRange(pcm, 1, 8, 1),
    expected,
    "the whole lower-priority player's voice is stolen even though its channel priority is the highest"
  )
end

function T.psg_voices_are_restricted_to_psg_capable_channels()
  local function renderWith(generator, channelMask, frames)
    local mixer = newMixer()
    local channel = mixer:noteOn(spec({ generator = generator, channelMask = channelMask }))
    return channel, frameRange(mixer:render(frames), 1, frames, 1)
  end
  local squareSilent, squareOut = renderWith({ kind = "square", duty = 0.5 }, 0x00FF, 8)
  Assert.isNil(squareSilent, "a square voice has no channel inside mask 0x00FF (0-7)")
  for i = 1, 8 do
    Assert.equal(squareOut[i], 0)
  end
  local noiseSilent, noiseOut = renderWith({ kind = "noise" }, 0x00FF, 8)
  Assert.isNil(noiseSilent, "a noise voice has no channel inside mask 0x00FF (0-7)")
  for i = 1, 8 do
    Assert.equal(noiseOut[i], 0)
  end
  local _, squareOn13 = renderWith({ kind = "square", duty = 0.5 }, 0x2000, 8)
  Assert.notNil(squareOn13[1], "channel 13 is square-capable")
  local squareOn14, _ = renderWith({ kind = "square", duty = 0.5 }, 0x4000, 8)
  Assert.isNil(squareOn14, "channel 14 is noise-only, not square-capable")
  local noiseOn14, noise14 = renderWith({ kind = "noise" }, 0x4000, 8)
  Assert.notNil(noiseOn14, "channel 14 is noise-capable")
  Assert.equal(noise14[1], -32767)
end

function T.sample_voices_allocate_only_within_the_player_mask()
  local mixer = newMixer()
  local mask = 0x0003
  local waveA = spec({ channelMask = mask })
  local waveB = spec({ pcm = AudioFixture.pcm16le(wave(2)), channelMask = mask })
  local waveC = spec({ pcm = AudioFixture.pcm16le(wave(3)), channelMask = mask })
  local waveD = spec({ pcm = AudioFixture.pcm16le(wave(4)), channelMask = mask })
  mixer:noteOn(waveA)
  mixer:noteOn(waveB)
  local channelC = mixer:noteOn(waveC)
  local channelD = mixer:noteOn(waveD)
  Assert.notNil(channelC)
  Assert.notNil(channelD)
  local pcm = mixer:render(8)
  local expected = {}
  for i = 1, 8 do
    expected[i] = wave(3)[i] + wave(4)[i]
  end
  Assert.deepEqual(frameRange(pcm, 1, 8, 1), expected, "the two oldest voices were evicted inside the mask")
  mixer:noteOff(channelC)
  local after = mixer:render(8)
  Assert.deepEqual(frameRange(after, 1, 8, 1), wave(4), "the evicted slot carried wave C")
end

function T.mixing_sums_and_saturates()
  local mixer = newMixer()
  local loud = { 30000, -30000, 30000, -30000, 30000, -30000, 30000, -30000 }
  mixer:noteOn(spec({ pcm = AudioFixture.pcm16le(loud) }))
  mixer:noteOn(spec({ pcm = AudioFixture.pcm16le(loud) }))
  local pcm = mixer:render(8)
  Assert.deepEqual(
    frameRange(pcm, 1, 8, 1),
    { 32767, -32768, 32767, -32768, 32767, -32768, 32767, -32768 },
    "the mix saturates at the int16 bounds"
  )
end

function T.render_is_deterministic_and_chunk_independent()
  local function playChunked(chunks)
    local mixer = newMixer()
    mixer:noteOn(spec())
    local out = {}
    for _, frames in ipairs(chunks) do
      local pcm = mixer:render(frames)
      for i = 1, #pcm do
        out[#out + 1] = pcm[i]
      end
    end
    return out
  end
  Assert.deepEqual(playChunked({ 120 }), playChunked({ 40, 40, 40 }), "chunk size does not change the rendered PCM")
  Assert.deepEqual(playChunked({ 120 }), playChunked({ 120 }), "rendering is reproducible")
end

return { tests = T }
