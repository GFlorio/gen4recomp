-- Deterministic recording stand-in for the LÖVE audio-output host boundary.
-- It mirrors the real host contract the production LoveAudioSink consumes,
-- including the semantics the old total-scalar model got wrong:
--
--   * SoundData is constructed with a FRAME count (sample points per channel,
--     real LÖVE allocates frames * bytesPerSample * channels), so
--     getSampleCount() reports frames per channel -- never the interleaved
--     scalar total -- and `sound` buffers that silent second half would have
--     no room for.
--   * The queueable source takes an explicit buffer count (omitted buffer
--     counts silently adopt LÖVE's default of 8 buffers; the double refuses
--     that so the explicit-buffer-count contract fails loudly). getFreeBufferCount
--     reports bufferCount minus queued, while the simulated playback head
--     drains one queued buffer per free-count query while playing -- the
--     recording equivalent of the host returning finished buffers to the free
--     pool. queue() returns a success boolean and refuses (false, unrecorded)
--     a full queue, exactly like the real binding.
--
-- It records every chunk handed to the host and never touches an audio
-- device; the non-silence probes read the queued samples the way the host
-- would decode them.

local FakeAudioOutput = {}
FakeAudioOutput.__index = FakeAudioOutput

-- The SoundData-shaped record the `sound` namespace creates. `frames` is the
-- per-channel sample/frame count (real love.sound.newSoundData allocates
-- frames * bytesPerSample * channels); channels are 1-based; sample values are
-- floats in [-1, 1].
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

-- Sample points per channel: the constructor's frame count, never the total
-- number of interleaved scalar values.
function SoundData:getSampleCount()
  return self.sampleCount
end

function SoundData:getSample(i, channel)
  assert(self:_inRange(i, channel), "sample out of range")
  return self.samples[i * self.channels + (channel - 1)] or 0
end

function SoundData:setSample(i, channel, sample)
  assert(self:_inRange(i, channel), "sample out of range")
  self.samples[i * self.channels + (channel - 1)] = sample
end

function SoundData:_inRange(i, channel)
  return i >= 0 and channel >= 1 and channel <= self.channels and i < self.sampleCount
end

function SoundData:release() end

-- The queueable source the `audio` namespace creates. `bufferCount` is the
-- explicit queue depth; `queued` counts buffers handed in but not yet played
-- to the end.
local Source = {}
Source.__index = Source

function Source:getFreeBufferCount()
  -- The playback head drains one queued buffer per free-count query while
  -- playing (the real host's pool returns finished buffers to the free pool),
  -- so the pump keeps receiving fresh free buffers at the drain rate.
  if self.playing and self.queued > 0 then
    self.queued = self.queued - 1
  end
  return self.bufferCount - self.queued
end

function Source:queue(data)
  assert(
    type(data) == "table"
      and type(data.getSample) == "function"
      and type(data.getSampleCount) == "function"
      and type(data.getChannelCount) == "function",
    "queued payload must be SoundData-shaped (a Lua byte string is not queueable)"
  )
  if self.queued >= self.bufferCount then
    return false
  end
  self:record(data)
  self.queued = self.queued + 1
  return true
end

function Source:play()
  self.playing = true
end

function Source:stop()
  self.playing = false
end

function Source:isPlaying()
  return self.playing == true
end

function Source:release() end

function FakeAudioOutput.new()
  local chunks = {}

  -- Reads the queued SoundData at handoff time (the host copies what it
  -- decodes) and records whether it contains any nonzero sample.
  local function record(chunks, data)
    local nonZero = false
    for frame = 0, data:getSampleCount() - 1 do
      for channel = 1, data:getChannelCount() do
        if data:getSample(frame, channel) ~= 0 then
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

  local sound = {
    newSoundData = function(frames, sampleRate, bitDepth, channels)
      assert(type(frames) == "number" and type(sampleRate) == "number" and type(bitDepth) == "number")
      assert(type(channels) == "number")
      return setmetatable({
        sampleRate = sampleRate,
        bitDepth = bitDepth,
        channels = channels,
        sampleCount = frames,
        samples = {},
      }, SoundData)
    end,
  }

  local audio = {
    newQueueableSource = function(sampleRate, bitDepth, channels, bufferCount)
      assert(type(sampleRate) == "number" and type(bitDepth) == "number" and type(channels) == "number")
      -- Real LÖVE falls back to its default of 8 buffers when the count is
      -- omitted; the double rejects that so a production call that relies on
      -- the accidental host default fails loudly instead of silently adopting
      -- an unbudgeted queue depth.
      assert(bufferCount ~= nil and bufferCount >= 1, "queueable source requires an explicit buffer count")
      return setmetatable({
        sampleRate = sampleRate,
        bitDepth = bitDepth,
        channels = channels,
        bufferCount = bufferCount,
        queued = 0,
        playing = false,
        record = function(_, data)
          record(chunks, data)
        end,
      }, Source)
    end,
  }

  local self = setmetatable({
    chunks = chunks,
    audio = audio,
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
