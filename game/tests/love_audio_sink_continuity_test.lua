-- QueueableSource continuity tests use an independent audio clock. The host
-- consumes queued PCM between sink updates, so free slots are derived from
-- completed 512-frame buffers rather than a scripted sequence.

local Assert = require("tests.support.Assert")
local LoveAudioSink = require("game.src.audio.LoveAudioSink")

local SAMPLE_RATE = 32768
local CHANNELS = 2
local BUFFER_COUNT = 4

local function newDevice()
  local device = { sources = {}, underruns = 0, queuedFrames = 0 }

  local function source()
    local current = {
      queued = {},
      playing = false,
      started = false,
      underrunCount = 0,
    }

    function current:queue(data)
      if #self.queued >= BUFFER_COUNT then
        return false
      end
      self.queued[#self.queued + 1] = data:getSampleCount()
      device.queuedFrames = device.queuedFrames + data:getSampleCount()
      return true
    end

    function current:getFreeBufferCount()
      return BUFFER_COUNT - #self.queued
    end

    function current:play()
      self.playing = true
      self.started = true
    end

    function current:isPlaying()
      return self.playing
    end

    function current:release() end

    function current:consume(frames)
      while frames > 0 and #self.queued > 0 do
        local available = self.queued[1]
        local consumed = math.min(frames, available)
        available = available - consumed
        frames = frames - consumed
        if available == 0 then
          table.remove(self.queued, 1)
        else
          self.queued[1] = available
        end
      end
      if self.playing and #self.queued == 0 then
        self.playing = false
        self.underrunCount = self.underrunCount + 1
        device.underruns = device.underruns + 1
      end
    end

    device.sources[#device.sources + 1] = current
    return current
  end

  device.audio = {
    newQueueableSource = function(_, _, _, bufferCount)
      Assert.equal(bufferCount, BUFFER_COUNT)
      return source()
    end,
  }
  device.sound = {
    newSoundData = function(frames)
      return {
        getSampleCount = function()
          return frames
        end,
        setSample = function() end,
        release = function() end,
      }
    end,
  }
  function device:advance(seconds)
    self.sources[1]:consume(seconds * SAMPLE_RATE)
  end
  return device
end

local function newSink(device)
  device.renderedFrames = 0
  return LoveAudioSink.new({
    audio = device.audio,
    sound = device.sound,
    sampleRate = SAMPLE_RATE,
    renderer = {
      render = function(_, frames)
        device.renderedFrames = device.renderedFrames + frames
        local pcm = {}
        for _ = 1, frames * CHANNELS do
          pcm[#pcm + 1] = 0
        end
        return pcm
      end,
    },
  })
end

local function runSchedule(schedule, seconds, phaseOffset)
  local device = newDevice()
  local sink = newSink(device)
  sink:update()
  if phaseOffset ~= nil then
    device:advance(phaseOffset)
    sink:update()
  end
  local elapsed = 0
  local index = 1
  while elapsed < seconds do
    local interval = schedule[index]
    index = index % #schedule + 1
    device:advance(interval)
    sink:update()
    elapsed = elapsed + interval
  end
  return sink, device
end

local T = {}

function T.ideal_pumping_stays_continuous_for_ten_seconds()
  local sink, device = runSchedule({ 1 / 60 }, 10)
  Assert.equal(sink:getUnderrunCount(), 0)
  Assert.equal(device.underruns, 0)
  Assert.equal(device.renderedFrames, device.queuedFrames)
end

function T.phase_offsets_stay_continuous_for_ten_seconds()
  for _, offset in ipairs({ 0, 0.005, 0.010, 0.015 }) do
    local sink, device = runSchedule({ 1 / 60 }, 10, offset)
    Assert.equal(sink:getUnderrunCount(), 0)
    Assert.equal(device.underruns, 0)
  end
end

function T.bounded_jitter_stays_continuous_for_ten_seconds()
  local sink, device = runSchedule({ 0.014, 0.019, 0.016, 0.018 }, 10)
  Assert.equal(sink:getUnderrunCount(), 0)
  Assert.equal(device.underruns, 0)
end

function T.a_forty_millisecond_hitch_stays_continuous()
  local device = newDevice()
  local sink = newSink(device)
  sink:update()
  for _ = 1, 120 do
    device:advance(1 / 60)
    sink:update()
  end
  device:advance(0.040)
  sink:update()
  for _ = 1, 480 do
    device:advance(1 / 60)
    sink:update()
  end
  Assert.equal(sink:getUnderrunCount(), 0)
  Assert.equal(device.underruns, 0)
end

function T.a_gap_beyond_queue_budget_is_measured_once_and_recovered()
  local device = newDevice()
  local sink = newSink(device)
  sink:update()
  device:advance(1)
  sink:update()
  Assert.equal(sink:getUnderrunCount(), 1)
  Assert.equal(device.underruns, 1)
  sink:update()
  Assert.equal(sink:getUnderrunCount(), 1)
end

return { tests = T }
