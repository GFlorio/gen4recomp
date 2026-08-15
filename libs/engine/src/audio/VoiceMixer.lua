-- Deterministic 16-channel DS sound engine per the ARM7 NitroSDK
-- (SND_exChannel.c, SND_util.c, SND_bank.c, SND_seq.c) and GBATEK
-- ("DS Sound" chapter). The mixer owns per-voice NNS channel behavior and
-- the physical host boundary:
--   * Volume is a dB-like integer sum per control step
--     (SNDi_DecibelSquareTable[velocity] + envAttenuation>>7 +
--     DecibelSquare[trackVolume] + DecibelSquare[expression] +
--     DecibelSquare[playerVolume] + fader), converted once per step by
--     SND_CalcChannelVolume; the host gain is the register mantissa N/128
--     (127 -> 128) >> sSampleDataShiftTable.
--   * The envelope is the SDK state machine (SND_SetExChannelAttack
--     coefficients, CalcDecayCoeff decay/release with the 127/126 special
--     cases, DecibelSquare[sustain]<<7 decay target, release stopped when
--     the dB sum crosses the vol <= -723 threshold at the step count
--     NnsSoundMath.releaseStopSteps precomputed), advanced once per control
--     step -- 192 Hz, one step per outputRate/192 frames (SND_TIMER_RATE
--     240 at the 192 Hz sound interval). The noteOn itself is the note's
--     first control step.
--   * Pitch is the integer domain (key - originalKey)*0x40 through
--     SND_CalcTimer (BIOS pitch table); square timers are masked with
--     0xFFFC and square/noise use the 8006 base timer; the host phase
--     increment is sampleRate*baseTimer/(timer*outputRate) for samples and
--     the DS sample clock/(timer*outputRate) for square/noise.
--   * Pan has three distinct domains: the instrument pan (initPan =
--     pan - 0x40), the track pan offset (TrackUpdateChannel: scaled by
--     panRange, starts 0), and the final hardware register (initPan +
--     userPan + 0x40, clamped 0..127) feeding the linear hardware mix
--     (128-N)/128 and N/128 with register 127 as N=128.
--   * Allocation is SND_AllocExChannel: the fixed order
--     {4,5,6,7,2,0,3,1,8,9,10,11,14,12,15,13} inside (generator range AND
--     channelMask); the victim is the lowest effective priority
--     (playerPriority + trackPriority, one sum) and among equals the
--     quieter last-synced volume register; an incoming note below the
--     victim's priority is rejected; a stolen channel revokes the previous
--     voice handle. noteOn returns {channel, generation} (generation
--     0-based, incremented per channel reuse) or nil; noteOff/updateVoice
--     on a stale handle are harmless.
--   * LFO (SND_UpdateLfo/SND_GetLfoValue/SND_SinIdx) and sweep
--     (ExChannelSweepUpdate) state machines run per control step and feed
--     the pitch/volume/pan calculations; the sweep counter advances only
--     at control steps (a noteOn's own step contributes the full
--     sweepPitch without advancing the counter).
--   * Square duty is the discrete 0..7 index (8-sample cycle starting at
--     LOW, HIGH=(d+1)*12.5%); noise is the 15-bit LFSR from 7FFFh
--     (X = X SHR 1; carry -> LOW and X = X XOR 6000h, else HIGH).
-- Commands between renders apply at the next control step; control steps
-- fire on the mixer's absolute frame count, so rendering is independent of
-- chunk size. Output is interleaved stereo int16; mixing sums and
-- saturates at +-32767/+-32768; per-voice host gains round with
-- floor(x+0.5).

local bit = require("bit")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")

---@class VoiceMixer
---@field private _sampleRate integer
---@field private _channels table<integer, table>
---@field private _frameCount integer
---@field private _controlPeriod integer
---@field new fun(opts: { sampleRate: integer }): VoiceMixer
---@field noteOn fun(self: VoiceMixer, spec: table): { channel: integer, generation: integer } | nil
---@field noteOff fun(self: VoiceMixer, handle: { channel: integer, generation: integer })
---@field updateVoice fun(self: VoiceMixer, handle: { channel: integer, generation: integer }, partial: table)
---@field render fun(self: VoiceMixer, frames: integer): integer[]

local VoiceMixer = {}
VoiceMixer.__index = VoiceMixer

-- DS hardware channel count; the PSG ranges live inside the generator
-- masks below.
local CHANNEL_COUNT = 16

-- The generator's allocatable channel mask (SND_seq.c TrackPlayNote):
-- sample on all 16, square only on 8..13, noise only on 14..15 (GBATEK
-- "NDS Sound": PSG rectangular wave only on those ranges).
local GENERATOR_MASK = {
  sample = 0xFFFF,
  square = 0x3F00,
  noise = 0xC000,
}

-- The fixed extended-channel allocation order (wram2.s
-- sChannelAllocationOrder).
local ALLOCATION_ORDER = { 4, 5, 6, 7, 2, 0, 3, 1, 8, 9, 10, 11, 14, 12, 15, 13 }

-- The register divider shifts (wram2.s sSampleDataShiftTable).
local SAMPLE_DATA_SHIFT = { 0, 1, 2, 4 }

-- The PSG/noise base timer and the DS sample clock (SND_exChannel.c
-- SND_StartExChannelPsg/Noise; GBATEK: 16.757 MHz sample clock).
local PSG_BASE_TIMER = 8006
local DS_SAMPLE_CLOCK = 16756991

-- The envelope starts fully attenuated (SND_exChannel.c ExChannelStart);
-- the release stops when the dB sum crosses the SDK threshold, computed by
-- NnsSoundMath.releaseStopSteps.
local ENV_START = -92544

-- The 192 Hz sound interval (SND_main.c SndThread); control steps fire
-- every outputRate/192 frames.
local SOUND_INTERVAL = 192

-- Phase snap for square/noise: the pinned duty and LFSR boundaries sit on
-- exact frame multiples of the timer, and the float phase accumulation may
-- land a few ulp below an integer; the snap is far smaller than the
-- 1/timer gap between genuine states (timers are at most 0xFFFF).
local PHASE_SNAP = 1e-6

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function int16At(bytes, index)
  local low = bytes:byte(index * 2 + 1)
  local high = bytes:byte(index * 2 + 2)
  local value = low + high * 256
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

-- Decodes the PCM16LE payload into a table of int16 samples.
---@param bytes string
---@return integer[]
local function decodePcm(bytes)
  assert(#bytes % 2 == 0, "PCM16LE payload has an odd byte count")
  local samples = {}
  for index = 0, #bytes / 2 - 1 do
    samples[index + 1] = int16At(bytes, index)
  end
  return samples
end

-- Saturates the summed sample at the int16 bounds.
---@param value integer
---@return integer
local function saturate(value)
  if value > 32767 then
    return 32767
  end
  if value < -32768 then
    return -32768
  end
  return value
end

-- ExChannelVolumeCmp: the allocation tie-break compares the last-synced
-- volume register (mantissa<<4 >> sSampleDataShiftTable[divider]); a free
-- channel has a zero register. Returns 1 when a is quieter, -1 when louder,
-- 0 on a tie.
---@param a table?
---@param b table?
---@return integer
local function volumeCmp(a, b)
  local va = a and a.volume or 0
  local vb = b and b.volume or 0
  local ma = bit.lshift(bit.band(va, 0xFF), 4)
  local mb = bit.lshift(bit.band(vb, 0xFF), 4)
  ma = bit.rshift(ma, SAMPLE_DATA_SHIFT[bit.rshift(va, 8) + 1])
  mb = bit.rshift(mb, SAMPLE_DATA_SHIFT[bit.rshift(vb, 8) + 1])
  if ma ~= mb then
    if ma < mb then
      return 1
    end
    return -1
  end
  return 0
end

-- SND_AllocExChannel: inside (generator range AND channelMask), the first
-- free channel in the fixed order wins; when all are occupied the victim
-- is the lowest (priority, then quieter last-synced register). An incoming
-- note below the chosen occupied channel's priority is rejected. Returns
-- the channel and the current occupant (nil when free).
---@param kind string
---@param channelMask integer
---@param priority integer
---@return integer?, table?
local function allocateChannel(self, kind, channelMask, priority)
  local allowed = bit.band(GENERATOR_MASK[kind], channelMask)
  local chosenChannel, chosenVoice
  for _, candidate in ipairs(ALLOCATION_ORDER) do
    if bit.band(allowed, bit.lshift(1, candidate)) ~= 0 then
      local voice = self._channels[candidate]
      if chosenChannel == nil then
        chosenChannel = candidate
        chosenVoice = voice
      else
        local voicePriority = voice and voice.priority or 0
        local chosenPriority = chosenVoice and chosenVoice.priority or 0
        if
          voicePriority <= chosenPriority
          and (voicePriority ~= chosenPriority or volumeCmp(chosenVoice, voice) < 0)
        then
          chosenChannel = candidate
          chosenVoice = voice
        end
      end
    end
  end
  if chosenChannel == nil then
    return nil
  end
  if chosenVoice ~= nil and priority < chosenVoice.priority then
    return nil
  end
  return chosenChannel, chosenVoice
end

-- The volume register's host gain: mantissa N/128 (127 -> 128) divided by
-- the divider shift (GBATEK "7bit Volume and Panning Values" and
-- "Channel/Mixer Bit-Widths").
---@param register integer
---@return number
local function registerGain(register)
  local mantissa = bit.band(register, 0xFF)
  local n = mantissa == 127 and 128 or mantissa
  local shift = SAMPLE_DATA_SHIFT[bit.rshift(register, 8) + 1]
  return n / 128 / (2 ^ shift)
end

-- The linear hardware pan mix from the pan register (register 127 read as
-- N = 128, so the extremes are full gain on one side).
---@param register integer
---@return number, number
local function panMix(register)
  local n = register == 127 and 128 or register
  return (128 - n) / 128, n / 128
end

-- The discrete square duty index 0..7. The asset contract carries the
-- exact dyadic fraction (N+1)/8 (the compiler emits it from the source
-- duty byte), and the conversion is exact: the 8/8 = 1.0 fraction maps to
-- index 7 (100% HIGH).
---@param duty number
---@return integer
local function dutyIndex(duty)
  local index = math.floor(duty * 8 + 0.5) - 1
  assert(index >= 0 and index <= 7, "square duty out of range")
  return index
end

-- ---------------------------------------------------------------------------
-- Voices

-- The per-note voice state: the SDK channel fields, the track-pushed user
-- values pending the next control step, and the generator playback state.
---@param spec table
---@return table
local function newVoice(spec)
  local generator = spec.generator
  assert(spec.originalKey ~= nil, "voice spec requires the original key")
  local voice = {
    generator = generator,
    midiKey = spec.key,
    rootMidiKey = spec.originalKey,
    velocity = spec.velocity,
    envAttenuation = ENV_START,
    envStatus = "attack",
    envAttack = NnsSoundMath.attackCoefficient(spec.envelope.attack),
    envDecay = NnsSoundMath.decayCoefficient(spec.envelope.decay),
    envSustain = spec.envelope.sustain,
    envRelease = NnsSoundMath.decayCoefficient(spec.envelope.release),
    initPan = spec.pan - 0x40,
    pending = {
      trackVolume = spec.trackVolume,
      expression = spec.expression,
      playerVolume = spec.playerVolume,
      fader = spec.fader or 0,
      trackPanOffset = spec.trackPanOffset or 0,
      panRange = spec.panRange or 127,
      lfo = spec.lfo or { target = 0, depth = 0, range = 1, speed = 16, delay = 0 },
      sweepCounter = nil,
      dirty = true,
    },
    sweepPitch = spec.sweepPitch or 0,
    sweepLength = spec.sweepLength or 0,
    sweepCounter = 0,
    autoSweep = spec.autoSweep ~= false,
    lfoCounter = 0,
    lfoDelayCounter = 0,
    -- The last-synced registers (the volume feeds the allocation tie-break).
    volume = 0,
    timer = 0,
    pan = 0,
    ratio = 0,
    released = false,
    dead = false,
    baseTimer = PSG_BASE_TIMER,
  }
  if generator.kind == "sample" then
    voice.pcm = decodePcm(spec.pcm)
    voice.baseTimer = spec.baseTimer
    voice.sampleRate = spec.sampleRate
    voice.pos = 0
    voice.loop = spec.loop
    voice.loopEnabled = spec.loopEnabled
  elseif generator.kind == "square" then
    voice.duty = dutyIndex(generator.duty)
    voice.phase = 0
  else
    voice.phase = 0
    voice.lfsr = 0x7FFF
  end
  return voice
end

-- TrackUpdateChannel: the track-level values become the channel's user
-- values (the dB sum is clamped at -0x8000; the pan offset is scaled by
-- the panRange when it is not 127).
---@param voice table
local function applyPending(voice)
  local pending = voice.pending
  local vol = NnsSoundMath.decibelSquare(pending.trackVolume)
    + NnsSoundMath.decibelSquare(pending.expression)
    + NnsSoundMath.decibelSquare(pending.playerVolume)
  if vol < -0x8000 then
    vol = -0x8000
  end
  voice.userDecay = vol
  local fader = pending.fader
  if fader < -0x8000 then
    fader = -0x8000
  end
  voice.userDecay2 = fader
  if pending.panRange == 127 then
    voice.userPan = pending.trackPanOffset
  else
    voice.userPan = math.floor((pending.trackPanOffset * pending.panRange + 0x40) / 128)
  end
  voice.lfoParam = pending.lfo
  -- The sweep counter is voice-owned state (the autoSweep advance); a
  -- pushed sweepCounter from updateVoice overrides it.
  if pending.sweepCounter ~= nil then
    voice.sweepCounter = pending.sweepCounter
  end
  -- The tie partials: key retunes the pitch path, velocity re-enters the
  -- dB sum; both leave the envelope and the release/attack status alone.
  if pending.key ~= nil then
    voice.midiKey = pending.key
  end
  if pending.velocity ~= nil then
    voice.velocity = pending.velocity
  end
  pending.dirty = false
end

-- The LFO value for the current counter state (SND_GetLfoValue), scaled by
-- the target (SND_exChannel.c ExChannelLfoUpdate): 0 while the delay
-- counter runs or the depth is zero.
---@param voice table
---@return integer
local function lfoValue(voice)
  local param = voice.lfoParam
  if param.depth == 0 or voice.lfoDelayCounter < param.delay then
    return 0
  end
  local value = NnsSoundMath.sinIdx(math.floor(voice.lfoCounter / 256)) * param.depth * param.range
  if value ~= 0 then
    if param.target == 1 then
      value = value * 60
    else
      value = value * 64
    end
    value = math.floor(value / 16384)
  end
  return value
end

-- SND_UpdateLfo: the delay counter advances first; once the delay is
-- exhausted the 8.8 fixed-point counter advances by speed<<6 with the high
-- byte wrapped at 0x80.
---@param voice table
local function advanceLfo(voice)
  local param = voice.lfoParam
  if voice.lfoDelayCounter < param.delay then
    voice.lfoDelayCounter = voice.lfoDelayCounter + 1
  else
    local high = math.floor((voice.lfoCounter + param.speed * 64) / 256)
    while high >= 0x80 do
      high = high - 0x80
    end
    voice.lfoCounter = bit.band(voice.lfoCounter + param.speed * 64, 0xFF) + high * 256
  end
end

-- The host phase increment: the calculated NDS timer feeds the physical
-- boundary. Sample voices translate through their sample rate and base
-- timer; square/noise through the DS sample clock (so at a DS-rate mixer
-- the translation is exactly 1/timer).
---@param voice table
---@return number
local function voiceRatio(voice)
  if voice.generator.kind == "sample" then
    return voice.sampleRate * voice.baseTimer / (voice.timer * voice._outputRate)
  end
  return DS_SAMPLE_CLOCK / (voice.timer * voice._outputRate)
end

-- SND_ExChannelMain: the vol/pitch/pan computation and the register sync
-- from the current channel state (without advancing the envelope/sweep/LFO
-- state machines). The release stop fires when the noteOff-precomputed
-- releaseStepsRemaining is exhausted (the count NnsSoundMath
-- .releaseStopSteps derived from the dB sum and the release recurrence);
-- the -0x8000 volume-LFO guard lives here; the PSG timer is masked with
-- 0xFFFC.
---@param voice table
---@return boolean -- false when the voice hit the release stop threshold
local function syncRegisters(voice)
  local param = voice.lfoParam
  local lfo = lfoValue(voice)
  local vol = NnsSoundMath.decibelSquare(voice.velocity)
    + math.floor(voice.envAttenuation / 128)
    + voice.userDecay
    + voice.userDecay2
  if lfo ~= 0 and param.target == 1 and vol > -0x8000 then
    vol = vol + lfo
  end
  local pitch = (voice.midiKey - voice.rootMidiKey) * 0x40
  if lfo ~= 0 and param.target == 0 then
    pitch = pitch + lfo
  end
  local sweep = 0
  if voice.sweepPitch ~= 0 and voice.sweepCounter < voice.sweepLength then
    sweep = NnsSoundMath.cDiv(voice.sweepPitch * (voice.sweepLength - voice.sweepCounter), voice.sweepLength)
    pitch = pitch + sweep
  end
  local pan = voice.initPan
  if lfo ~= 0 and param.target == 2 then
    pan = pan + lfo
  end
  pan = pan + voice.userPan
  if voice.released and voice.envStatus == "release" and voice.releaseStepsRemaining <= 0 then
    voice.dead = true
    return false
  end
  voice.volume = NnsSoundMath.calcChannelVolume(vol)
  local timer = NnsSoundMath.calcTimer(voice.baseTimer, pitch)
  if voice.generator.kind == "square" then
    timer = bit.band(timer, 0xFFFC)
  end
  voice.timer = timer
  pan = pan + 0x40
  voice.pan = clamp(pan, 0, 127)
  voice.ratio = voiceRatio(voice)
  return true
end

-- One control step (SND_ExChannelMain(step = TRUE)): track values, then
-- the envelope advance (SND_UpdateExChannelEnvelope), the sweep counter
-- advance (only at regular steps, never at the noteOn step itself), the
-- LFO advance, and the register sync.
---@param voice table
---@param advanceSweep boolean
local function controlStep(voice, advanceSweep)
  applyPending(voice)
  if voice.envStatus == "attack" then
    voice.envAttenuation = -math.floor((-voice.envAttenuation * voice.envAttack) / 256)
    if voice.envAttenuation == 0 then
      voice.envStatus = "decay"
    end
  elseif voice.envStatus == "decay" then
    local sustain = NnsSoundMath.decibelSquare(voice.envSustain) * 128
    voice.envAttenuation = voice.envAttenuation - voice.envDecay
    if voice.envAttenuation <= sustain then
      voice.envAttenuation = sustain
      voice.envStatus = "sustain"
    end
  elseif voice.envStatus == "release" then
    voice.envAttenuation = voice.envAttenuation - voice.envRelease
    voice.releaseStepsRemaining = voice.releaseStepsRemaining - 1
  end
  if advanceSweep and voice.autoSweep and voice.sweepPitch ~= 0 and voice.sweepCounter < voice.sweepLength then
    voice.sweepCounter = voice.sweepCounter + 1
  end
  local alive = syncRegisters(voice)
  if alive then
    advanceLfo(voice)
  end
end

-- Reads the generator's sample at the current position and advances the
-- playback state by one frame (read-then-advance). One-shot waves stop at
-- the window end (the boundary sample still sounds).
---@param voice table
---@return integer
local function sampleAt(voice)
  if voice.generator.kind == "sample" then
    local sample = voice.pcm[math.floor(voice.pos) + 1]
    voice.pos = voice.pos + voice.ratio
    if voice.pos >= voice.loop.endFrame then
      if voice.loopEnabled then
        local span = voice.loop.endFrame - voice.loop.startFrame
        while voice.pos >= voice.loop.endFrame do
          voice.pos = voice.pos - span
        end
      else
        voice.dead = true
      end
    end
    return sample
  end
  if voice.generator.kind == "noise" then
    local sample = voice.lfsr % 2 == 1 and -32767 or 32767
    voice.phase = voice.phase + voice.ratio
    while voice.phase >= 1 - PHASE_SNAP do
      voice.phase = voice.phase - 1
      if voice.lfsr % 2 == 1 then
        voice.lfsr = bit.bxor(bit.rshift(voice.lfsr, 1), 0x6000)
      else
        voice.lfsr = bit.rshift(voice.lfsr, 1)
      end
    end
    return sample
  end
  local state = math.floor(voice.phase + PHASE_SNAP)
  local sample = state % 8 < (7 - voice.duty) and -32767 or 32767
  voice.phase = voice.phase + voice.ratio
  return sample
end

-- ---------------------------------------------------------------------------
-- Mixer

function VoiceMixer.new(opts)
  assert(opts and opts.sampleRate, "VoiceMixer requires a sampleRate")
  return setmetatable({
    _sampleRate = opts.sampleRate,
    _channels = {},
    _frameCount = 0,
    _controlPeriod = math.max(1, math.floor(opts.sampleRate / SOUND_INTERVAL)),
  }, VoiceMixer)
end

-- Starts a voice for `spec` (the NNS spec: trackVolume/trackPriority,
-- {channel, generation} handle). Returns nil when the note is rejected (no
-- allowed channel or priority below the chosen occupied channel's).
---@param spec table
---@return { channel: integer, generation: integer } | nil
function VoiceMixer:noteOn(spec)
  assert(spec and spec.generator and spec.envelope, "voice spec requires a generator and envelope")
  assert(
    spec.key ~= nil and spec.velocity ~= nil and spec.playerPriority ~= nil and spec.channelMask ~= nil,
    "voice spec requires key/velocity/playerPriority/channelMask"
  )
  assert(
    spec.trackVolume ~= nil and spec.expression ~= nil and spec.playerVolume ~= nil,
    "voice spec requires trackVolume/expression/playerVolume"
  )
  assert(spec.pan ~= nil and spec.trackPriority ~= nil, "voice spec requires pan/trackPriority")
  local priority = spec.playerPriority + spec.trackPriority
  local channel, victim = allocateChannel(self, spec.generator.kind, spec.channelMask, priority)
  if channel == nil then
    return nil
  end
  if spec.generator.kind == "sample" then
    assert(
      spec.pcm ~= nil and spec.sampleRate ~= nil and spec.baseTimer ~= nil and spec.loop ~= nil,
      "sample voice spec requires pcm/sampleRate/baseTimer/loop"
    )
    assert(type(spec.loopEnabled) == "boolean", "sample voice spec requires the wave's loop flag")
  end
  local voice = newVoice(spec)
  voice._outputRate = self._sampleRate
  voice.priority = priority
  voice.generation = victim and victim.generation + 1 or 0
  -- The noteOn itself is the note's first control step; the sweep counter
  -- does not advance on it (the contribution is the full sweepPitch).
  controlStep(voice, false)
  self._channels[channel] = voice
  return { channel = channel, generation = voice.generation }
end

-- Starts the release of the voice a handle names. A stale handle (channel
-- stolen, generation replaced) and a dead voice are harmless no-ops, as is
-- a note-off for a voice already releasing. The release runs
-- releaseStepsRemaining control steps (NnsSoundMath.releaseStopSteps from
-- the current dB-sum inputs and release coefficient) before the voice
-- stops.
---@param handle { channel: integer, generation: integer }
function VoiceMixer:noteOff(handle)
  local voice = self._channels[handle.channel]
  if voice == nil or voice.generation ~= handle.generation or voice.released or voice.dead then
    return
  end
  voice.released = true
  voice.envStatus = "release"
  -- The stop is precomputed from the queued (not yet applied) pending
  -- values: the pending apply precedes the first release decrement at the
  -- next control step.
  voice.releaseStepsRemaining = NnsSoundMath.releaseStopSteps({
    velocity = voice.velocity,
    envAttenuation = voice.envAttenuation,
    trackVolume = voice.pending.trackVolume,
    expression = voice.pending.expression,
    playerVolume = voice.pending.playerVolume,
    fader = voice.pending.fader,
    releaseCoeff = voice.envRelease,
  })
end

-- Queues track-level control values for the voice a handle names; they are
-- applied at the next control step. The `key` partial retunes the voice
-- through the note's pitch path (the timer/ratio recompute) without
-- touching the envelope or the release/attack status; `velocity` updates
-- the velocity in the volume dB sum. A stale or dead handle is harmless.
---@param handle { channel: integer, generation: integer }
---@param partial table
function VoiceMixer:updateVoice(handle, partial)
  local voice = self._channels[handle.channel]
  if voice == nil or voice.generation ~= handle.generation or voice.released or voice.dead then
    return
  end
  for key, value in pairs(partial) do
    voice.pending[key] = value
  end
  voice.pending.dirty = true
end

-- Renders `frames` output frames of interleaved stereo int16 PCM
-- (2*frames entries). Voices read at their position, advance
-- with the current ratio, and run a control step at the end of every
-- control-period frame on the mixer's absolute frame count; queued track
-- values are applied and the registers resynced at the start of the next
-- control-period frame. The mix sums and saturates at the int16 bounds;
-- chunk sizes never change the result.
---@param frames integer
---@return integer[]
function VoiceMixer:render(frames)
  local out = {}
  for frame = 1, frames do
    -- Queued track values apply at the start of the next control-period
    -- frame (the registers resync with the current channel state), so the
    -- boundary frame's own read hears them.
    if (self._frameCount + 1) % self._controlPeriod == 0 then
      for channel = 0, CHANNEL_COUNT - 1 do
        local voice = self._channels[channel]
        if voice ~= nil and voice.pending.dirty then
          applyPending(voice)
          syncRegisters(voice)
          if voice.dead then
            self._channels[channel] = nil
          end
        end
      end
    end
    local left, right = 0, 0
    for channel = 0, CHANNEL_COUNT - 1 do
      local voice = self._channels[channel]
      if voice ~= nil then
        local sample = sampleAt(voice)
        -- The one-shot boundary sample still sounds; the voice is
        -- removed after this frame.
        local gain = registerGain(voice.volume)
        local panLeft, panRight = panMix(voice.pan)
        left = left + math.floor(sample * gain * panLeft + 0.5)
        right = right + math.floor(sample * gain * panRight + 0.5)
        if voice.dead then
          self._channels[channel] = nil
        end
      end
    end
    out[#out + 1] = saturate(left)
    out[#out + 1] = saturate(right)
    self._frameCount = self._frameCount + 1
    if self._frameCount % self._controlPeriod == 0 then
      for channel = 0, CHANNEL_COUNT - 1 do
        local voice = self._channels[channel]
        if voice ~= nil then
          if not voice.dead then
            controlStep(voice, true)
          end
          if voice.dead then
            self._channels[channel] = nil
          end
        end
      end
    end
  end
  return out
end

return VoiceMixer
