-- Deterministic recording stand-in for the LÖVE audio-output host boundary.
-- It is shaped like the love.audio namespace the production LoveAudioSink
-- consumes (newQueueableSource + QueueableSource queue/play/stop/pause/
-- isPlaying/getFreeBufferCount/release), records every PCM chunk handed to the
-- host, and never touches an audio device. Chunks are little-endian s16
-- interleaved PCM (the engine render contract), decoded here for the
-- non-silence probes the field-audio scenarios assert.

local FakeAudioOutput = {}
FakeAudioOutput.__index = FakeAudioOutput

local BYTES_PER_SAMPLE = 2
local FREE_BUFFER_COUNT = 2

-- Decodes the little-endian s16 interleaved stereo chunk far enough to tell
-- whether it contains any nonzero sample (the non-silence probe the
-- field-audio scenarios assert).
---@param data string
---@return boolean nonZero
local function isNonZero(data)
  for index = 1, #data - 1, 2 do
    local lo = string.byte(data, index)
    local hi = string.byte(data, index + 1)
    local sample = hi * 256 + lo
    if sample >= 32768 then
      sample = sample - 65536
    end
    if sample ~= 0 then
      return true
    end
  end
  return false
end

function FakeAudioOutput.new()
  local chunks = {}
  local source = {}

  function source:queue(data)
    assert(
      type(data) == "string" and #data > 0 and #data % (BYTES_PER_SAMPLE * 2) == 0,
      "queued PCM must be s16 interleaved"
    )
    chunks[#chunks + 1] = { nonZero = isNonZero(data) }
  end

  function source:play()
    self.playing = true
  end

  function source:stop()
    self.playing = false
  end

  function source:pause()
    self.playing = false
  end

  function source:isPlaying()
    return self.playing == true
  end

  function source:getFreeBufferCount()
    return FREE_BUFFER_COUNT
  end

  function source:release()
    self.released = true
  end

  local self = setmetatable({
    chunks = chunks,
  }, FakeAudioOutput)

  function self.newQueueableSource(sampleRate, bitDepth, channels)
    assert(type(sampleRate) == "number" and type(bitDepth) == "number" and type(channels) == "number")
    return setmetatable({
      sampleRate = sampleRate,
      bitDepth = bitDepth,
      channels = channels,
      playing = false,
      released = false,
    }, { __index = source })
  end

  return self
end

-- True once any queued PCM chunk contained a nonzero sample (the music is
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
