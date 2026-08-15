-- The acceptance host fake must model the real LÖVE audio-output boundary
-- the production sink consumes: Source:queue accepts only SoundData-shaped
-- payloads and rejects the Lua byte strings the old sink encoded, and the
-- host's `sound` namespace creates SoundData-shaped buffers the sink can
-- populate. A fake that accepted interactions the production collaborator
-- rejects would let the string-queue regression pass silently.

local Assert = require("tests.support.Assert")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")

local T = {}

function T.queue_rejects_a_lua_byte_string_like_the_real_love_binding()
  local host = FakeAudioOutput.new()
  local source = host.audio.newQueueableSource(48000, 16, 2)
  Assert.throws(function()
    source:queue("\1\0\2\0\3\0\4\0")
  end)
  Assert.equal(#host.chunks, 0, "a rejected payload must not be recorded")
end

function T.sound_data_shaped_chunks_are_accepted_and_the_non_silence_probes_read_them()
  local host = FakeAudioOutput.new()
  local source = host.audio.newQueueableSource(48000, 16, 2)
  Assert.equal(source.sampleRate, 48000)
  Assert.equal(source.bitDepth, 16)
  Assert.equal(source.channels, 2)

  local chunk = host.sound.newSoundData(4, 48000, 16, 2)
  Assert.equal(chunk:getSampleRate(), 48000)
  Assert.equal(chunk:getBitDepth(), 16)
  Assert.equal(chunk:getChannelCount(), 2)
  Assert.equal(chunk:getSampleCount(), 4)
  chunk:setSample(0, 1, 0.5)
  chunk:setSample(0, 2, -0.5)
  source:queue(chunk)
  Assert.isTrue(host:anyNonSilent(), "the queued SoundData must drive the non-silence probe")

  source:queue(host.sound.newSoundData(4, 48000, 16, 2))
  source:queue(host.sound.newSoundData(4, 48000, 16, 2))
  Assert.equal(host:silentChunksSinceLastNonSilent(), 2)
end

return { tests = T }
