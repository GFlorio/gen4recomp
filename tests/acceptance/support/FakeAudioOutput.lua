-- Deterministic recording stand-in for the LÖVE audio-output host boundary.
-- It is shaped like the production LoveAudioSink's host contract: the
-- `audio` namespace creates queueable sources whose `queue` accepts only
-- SoundData-shaped payloads -- the real LÖVE binding rejects everything else,
-- in particular a Lua byte string -- and the `sound` namespace creates
-- SoundData-shaped buffers (total sample count, 1-based channel indices,
-- float samples in [-1, 1]). It records every chunk handed to the host and
-- never touches an audio device; the non-silence probes read the queued
-- samples the way the host would decode them.

local FakeAudioOutput = {}
FakeAudioOutput.__index = FakeAudioOutput

local CHANNELS = 2
local FREE_BUFFER_COUNT = 2

-- The SoundData-shaped record the `sound` namespace creates.
local SoundData = {}
SoundData.__index = SoundData

function SoundData:getSampleRate()
  return self.sampleRate
end

function SoundData:getBitDepth()
  return self.bitDepth
end

function SoundData:getChannelCount()
  return self.channels
end

function SoundData:getSampleCount()
  return self.sampleCount
end

function SoundData:getSample(i, channel)
  assert(
    i >= 0 and channel >= 1 and channel <= self.channels and i * self.channels + (channel - 1) < self.sampleCount,
    "sample out of range"
  )
  return self.samples[i * self.channels + (channel - 1)] or 0
end

function SoundData:setSample(i, channel, sample)
  assert(
    i >= 0 and channel >= 1 and channel <= self.channels and i * self.channels + (channel - 1) < self.sampleCount,
    "sample out of range"
  )
  self.samples[i * self.channels + (channel - 1)] = sample
end

function SoundData:release() end

function FakeAudioOutput.new()
  local chunks = {}
  local source = {}

  -- Whether a queued payload satisfies the real LÖVE SoundData contract the
  -- sink builds; a Lua byte string never does.
  local function isSoundData(data)
    return type(data) == "table"
      and type(data.getSample) == "function"
      and type(data.getSampleCount) == "function"
      and type(data.getChannelCount) == "function"
  end

  -- Reads the queued SoundData at handoff time (the host copies what it
  -- decodes) and records whether it contains any nonzero sample.
  local function record(chunks, data)
    local nonZero = false
    local frames = math.floor(data:getSampleCount() / data:getChannelCount())
    for index = 0, frames - 1 do
      for channel = 1, data:getChannelCount() do
        if data:getSample(index, channel) ~= 0 then
          nonZero = true
          break
        end
      end
      if nonZero then
        break
      end
    end
    chunks[#chunks + 1] = { nonZero = nonZero }
  end

  function source:queue(data)
    assert(isSoundData(data), "queued payload must be SoundData-shaped (got " .. type(data) .. ")")
    record(chunks, data)
  end

  function source:play()
    self.playing = true
  end

  function source:stop()
    self.playing = false
  end

  function source:isPlaying()
    return self.playing == true
  end

  function source:getFreeBufferCount()
    return FREE_BUFFER_COUNT
  end

  function source:release() end

  local sound = {
    newSoundData = function(samples, sampleRate, bitDepth, channels)
      assert(type(samples) == "number" and type(sampleRate) == "number" and type(bitDepth) == "number")
      assert(type(channels) == "number")
      return setmetatable({
        sampleRate = sampleRate,
        bitDepth = bitDepth,
        channels = channels,
        sampleCount = samples,
        samples = {},
      }, SoundData)
    end,
  }

  local self = setmetatable({
    chunks = chunks,
    audio = {
      newQueueableSource = function(sampleRate, bitDepth, channels)
        assert(type(sampleRate) == "number" and type(bitDepth) == "number" and type(channels) == "number")
        return setmetatable({
          sampleRate = sampleRate,
          bitDepth = bitDepth,
          channels = channels,
          playing = false,
        }, { __index = source })
      end,
    },
    sound = sound,
  }, FakeAudioOutput)

  return self
end

-- True once any queued chunk contained a nonzero sample (the music is
-- actually rendering into the host boundary).
function FakeAudioOutput:anyNonSilent()
  for _, chunk in ipairs(self.chunks) do
    if chunk.nonZero then
      return true
    end
  end
  return false
end

-- The number of chunks since the last chunk containing nonzero samples, or
-- the total chunk count when every chunk so far is silent.
function FakeAudioOutput:silentChunksSinceLastNonSilent()
  local silent = 0
  for index = #self.chunks, 1, -1 do
    if self.chunks[index].nonZero then
      return silent
    end
    silent = silent + 1
  end
  return silent
end

return FakeAudioOutput
