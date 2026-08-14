-- Deterministic DS-like 16-voice mixer. Sixteen channels;
-- sample voices allocate any channel, square only channels 8..13, noise
-- only 14..15 (GBATEK "NDS Sound" hardware chapter: format 3 is PSG-only on
-- those ranges), all restricted to the player's channelMask. Allocation is
-- the lowest free channel inside (generator range ∩ mask); when all are
-- occupied a new note steals the channel holding the lowest
-- (playerPriority, channelPriority, then oldest) voice inside the same
-- allowed set. Sample voices render nearest-sample (no interpolation),
-- loop inside their metadata loop window, and end only on
-- noteOff. Square duty cycles are 8 samples starting at LOW
-- (GBATEK: HIGH=(N+1)*12.5%); noise is the GBATEK 15-bit LFSR
-- (X=X SHR 1; carry -> LOW and X=X XOR 6000h, else HIGH; init 7FFFh).
-- The envelope is a project-defined linear model over the frozen 0..127
-- ADSR bytes (attack/decay/release ramp over (127-v)*8 frames, 127 =
-- instant; sustain is a level). Gain = velocity*volume*expression/127^3,
-- rounded to nearest; pan 0 = left only, 127 = right only, 64 = equal both.
-- Mixing sums and saturates at +-32767/+-32768. Output is interleaved
-- stereo int16 (2*frames entries); commands issued between renders apply at
-- the start of the next render.

local bit = require("bit")

---@class VoiceMixer
---@field private _sampleRate integer
---@field private _channels table<integer, table>
---@field private _nextOrder integer
---@field new fun(opts: { sampleRate: integer }): VoiceMixer
---@field noteOn fun(self: VoiceMixer, spec: table): integer?
---@field noteOff fun(self: VoiceMixer, channel: integer)
---@field render fun(self: VoiceMixer, frames: integer): integer[]

local VoiceMixer = {}
VoiceMixer.__index = VoiceMixer

-- DS hardware channel count; the PSG ranges below live inside it.
local CHANNEL_COUNT = 16

-- PSG-capable channel ranges (GBATEK "NDS Sound": PSG rectangular wave only
-- on channels 8..13, white noise only on 14..15; all 16 support PCM).
local SQUARE_FIRST, SQUARE_LAST = 8, 13
local NOISE_FIRST, NOISE_LAST = 14, 15

-- The one channel of the interleaved stereo output a sample lands on. The
-- pinned points are pan 0 = left only, 127 = right only, 64 = exactly equal
-- on both channels; the curve is a symmetric clamp through those points
-- (63/63 vs 64/63 both clamp to full), so any intermediate value is
-- unpinned pending the NNS pan-table verification.
local function panFactors(pan)
  return math.min(1, (127 - pan) / 63), math.min(1, pan / 63)
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

-- Decodes the PCM16LE payload into a table of int16 samples, once per voice
-- at note-on.
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

-- The level the envelope holds at (stage, stageFrame): attack ramps 0..1,
-- decay ramps 1..sustain/127, sustain holds, release ramps from its start
-- level to 0.
---@param stage string
---@param stageFrame integer
---@param adsr table
---@param sustainLevel number
---@param releaseStart number
---@return number
local function levelAt(stage, stageFrame, adsr, sustainLevel, releaseStart)
  local duration = (127 - adsr[stage]) * 8
  if stage == "attack" then
    return stageFrame / duration
  end
  if stage == "decay" then
    return 1 - (stageFrame / duration) * (1 - sustainLevel)
  end
  if stage == "sustain" then
    return sustainLevel
  end
  return releaseStart * (1 - stageFrame / duration)
end

-- Advances the envelope by one output frame and returns the per-frame level
-- multiplier, or nil when the voice ended (release ramp complete).
---@param voice table
---@return number?
local function envelopeAdvance(voice)
  while true do
    if voice.stage == "dead" then
      return nil
    end
    local duration = (127 - voice.adsr[voice.stage]) * 8
    if voice.stageFrame < duration then
      break
    end
    if voice.stage == "release" then
      voice.stage = "dead"
      return nil
    end
    if voice.stage == "sustain" then
      break
    end
    voice.stage = voice.nextStage[voice.stage]
    voice.stageFrame = 0
  end
  local level = levelAt(voice.stage, voice.stageFrame, voice.adsr, voice.sustainLevel, voice.releaseStart)
  voice.stageFrame = voice.stageFrame + 1
  return level
end

local function newVoice(spec, outputRate)
  local generator = spec.generator
  local voice = {
    generator = generator,
    adsr = spec.envelope,
    sustainLevel = spec.envelope.sustain / 127,
    stage = "attack",
    stageFrame = 0,
    nextStage = { attack = "decay", decay = "sustain", sustain = "sustain", release = "dead" },
    releaseStart = 0,
    gain = (spec.velocity / 127) * (spec.volume / 127) * (spec.expression / 127),
    channelPriority = spec.channelPriority,
    playerPriority = spec.playerPriority,
    order = 0,
  }
  voice.panLeft, voice.panRight = panFactors(spec.pan)
  if generator.kind == "sample" then
    assert(
      spec.pcm ~= nil and spec.sampleRate ~= nil and spec.loop ~= nil and spec.rootKey ~= nil,
      "sample voice spec requires pcm, sampleRate, loop and rootKey"
    )
    voice.pcm = decodePcm(spec.pcm)
    voice.ratio = (spec.sampleRate / outputRate) * 2 ^ ((spec.key - spec.rootKey) / 12)
    voice.pos = spec.loop.startFrame
    voice.loop = spec.loop
  elseif generator.kind == "square" then
    voice.high = math.floor(generator.duty * 8 + 0.5)
    voice.ratio = 2 ^ ((spec.key - 60) / 12)
    voice.phase = 0
  else
    voice.ratio = 2 ^ ((spec.key - 60) / 12)
    voice.phase = 0
    voice.lfsr = 0x7FFF
  end
  return voice
end

-- The generator's allocatable channel range: 0..15 for samples, 8..13 for
-- square, 14..15 for noise (GBATEK).
---@param kind string
---@return integer, integer
local function channelRange(kind)
  if kind == "square" then
    return SQUARE_FIRST, SQUARE_LAST
  end
  if kind == "noise" then
    return NOISE_FIRST, NOISE_LAST
  end
  return 0, CHANNEL_COUNT - 1
end

local function maskAllows(mask, channel)
  return bit.band(mask, bit.lshift(1, channel)) ~= 0
end

function VoiceMixer.new(opts)
  assert(opts and opts.sampleRate, "VoiceMixer requires a sampleRate")
  return setmetatable({
    _sampleRate = opts.sampleRate,
    _channels = {},
    _nextOrder = 0,
  }, VoiceMixer)
end

-- Starts a voice for `spec` and returns its channel, or nil when the
-- generator has no allowed channel inside the player's channelMask. When no
-- channel is free, the lowest-priority voice inside the allowed set is
-- stolen (lower playerPriority, then channelPriority, then oldest).
---@param spec table
---@return integer?
function VoiceMixer:noteOn(spec)
  assert(spec and spec.generator and spec.envelope, "voice spec requires a generator and envelope")
  assert(
    spec.key ~= nil and spec.velocity ~= nil and spec.volume ~= nil and spec.expression ~= nil,
    "voice spec requires key/velocity/volume/expression"
  )
  assert(
    spec.pan ~= nil and spec.channelPriority ~= nil and spec.playerPriority ~= nil and spec.channelMask ~= nil,
    "voice spec requires pan/priorities/channelMask"
  )
  local first, last = channelRange(spec.generator.kind)
  local channel
  for candidate = first, last do
    if maskAllows(spec.channelMask, candidate) and self._channels[candidate] == nil then
      channel = candidate
      break
    end
  end
  if channel == nil then
    local victim
    for candidate = first, last do
      if maskAllows(spec.channelMask, candidate) then
        local voice = self._channels[candidate]
        assert(voice, "a mask-allowed channel is either free or occupied")
        if
          victim == nil
          or voice.playerPriority < victim.playerPriority
          or (voice.playerPriority == victim.playerPriority and voice.channelPriority < victim.channelPriority)
          or (
            voice.playerPriority == victim.playerPriority
            and voice.channelPriority == victim.channelPriority
            and voice.order < victim.order
          )
        then
          victim = voice
          channel = candidate
        end
      end
    end
  end
  if channel == nil then
    return nil
  end
  local voice = newVoice(spec, self._sampleRate)
  voice.order = self._nextOrder
  self._nextOrder = self._nextOrder + 1
  self._channels[channel] = voice
  return channel
end

-- Starts the release stage of the voice on `channel`. An empty channel is
-- left untouched: a note-off never raises and never kills a voice it does
-- not own.
function VoiceMixer:noteOff(channel)
  local voice = self._channels[channel]
  if voice == nil or voice.stage == "dead" then
    return
  end
  if voice.stage ~= "release" then
    voice.releaseStart = levelAt(voice.stage, voice.stageFrame, voice.adsr, voice.sustainLevel, voice.releaseStart)
    voice.stage = "release"
    voice.stageFrame = 0
  end
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

-- Renders `frames` output frames of interleaved stereo int16 PCM (2*frames
-- entries). Voices advance once per frame; the mix sums and saturates at
-- the int16 bounds. Rendering is per-frame, so chunk sizes do not change
-- the result.
---@param frames integer
---@return integer[]
function VoiceMixer:render(frames)
  local out = {}
  for frame = 1, frames do
    local left, right = 0, 0
    for channel, voice in pairs(self._channels) do
      local level = envelopeAdvance(voice)
      if level == nil then
        self._channels[channel] = nil
      else
        local sample
        if voice.generator.kind == "sample" then
          sample = voice.pcm[math.floor(voice.pos) + 1]
          voice.pos = voice.pos + voice.ratio
          local span = voice.loop.endFrame - voice.loop.startFrame
          while voice.pos >= voice.loop.endFrame do
            voice.pos = voice.pos - span
          end
        else
          if voice.generator.kind == "noise" then
            sample = voice.lfsr % 2 == 1 and -32767 or 32767
            voice.phase = voice.phase + voice.ratio
            while voice.phase >= 1 do
              voice.phase = voice.phase - 1
              if voice.lfsr % 2 == 1 then
                voice.lfsr = bit.bxor(bit.rshift(voice.lfsr, 1), 0x6000)
              else
                voice.lfsr = bit.rshift(voice.lfsr, 1)
              end
            end
          else
            sample = (math.floor(voice.phase) % 8) < (8 - voice.high) and -32767 or 32767
            voice.phase = voice.phase + voice.ratio
          end
        end
        left = left + math.floor(sample * voice.gain * level * voice.panLeft + 0.5)
        right = right + math.floor(sample * voice.gain * level * voice.panRight + 0.5)
      end
    end
    out[#out + 1] = saturate(left)
    out[#out + 1] = saturate(right)
  end
  return out
end

return VoiceMixer
