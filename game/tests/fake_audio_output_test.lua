-- The acceptance host fake must model the real LÖVE audio-output boundary the
-- production sink consumes: Source:queue accepts only SoundData-shaped
-- payloads, returns a success boolean, and refuses a full queue (false,
-- unrecorded); the `sound` namespace builds SoundData buffers whose
-- getSampleCount() is the frame count per channel (not the interleaved scalar
-- total the old model assumed); and the queueable source requires an explicit
-- buffer count instead of adopting LÖVE's accidental default depth. A fake
-- that accepted interactions the production collaborator rejects would let the
-- wrong-behavior regressions pass silently.

local Assert = require("tests.support.Assert")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")

local T = {}

local SAMPLE_RATE = 32768
local BIT_DEPTH = 16
local CHANNELS = 2

function T.queue_rejects_a_lua_byte_string_like_the_real_love_binding()
  local host = FakeAudioOutput.new()
  local source = host.audio.newQueueableSource(SAMPLE_RATE, BIT_DEPTH, CHANNELS, 2)
  Assert.throws(function()
    source:queue("\1\0\2\0\3\0\4\0")
  end)
  Assert.equal(#host.chunks, 0, "a rejected payload must not be recorded")
end

-- A canonical example of the frame model the fake must mirror:
-- a 1024-frame stereo buffer gets getSampleCount() 1024 -- not 2048 -- and
-- frame 1023 is the last frame, holding scalar values 2047/2048. There is no
-- second interleaved half and no frame beyond 1023.
function T.new_sound_data_is_a_frames_per_channel_buffer_like_real_love()
  local host = FakeAudioOutput.new()
  local chunk = host.sound.newSoundData(1024, SAMPLE_RATE, BIT_DEPTH, CHANNELS)
  Assert.equal(chunk:getSampleCount(), 1024, "getSampleCount is frames per channel, not total interleaved scalars")
  chunk:setSample(0, 1, 1 / 32768)
  chunk:setSample(0, 2, 2 / 32768)
  chunk:setSample(1023, 1, 2047 / 32768)
  chunk:setSample(1023, 2, 2048 / 32768)
  Assert.equal(chunk:getSample(0, 1), 1 / 32768)
  Assert.equal(chunk:getSample(0, 2), 2 / 32768)
  Assert.equal(chunk:getSample(1023, 1), 2047 / 32768)
  Assert.equal(chunk:getSample(1023, 2), 2048 / 32768)
  -- A frame 1024 must not exist, so writing or reading one raises exactly
  -- like real LÖVE.
  Assert.throws(function()
    chunk:getSample(1024, 1)
  end, "no additional frame may exist beyond the requested frame count")
  Assert.throws(function()
    chunk:setSample(1024, 1, 0.5)
  end, "no additional frame may be writable beyond the requested frame count")
end

-- The source queue accounting is explicit and buffer-count-driven: a brand-new
-- source advertises its full buffer count, and a queue beyond it is refused
-- (returns false) without being recorded as delivered.
function T.queue_returns_a_success_boolean_and_refuses_when_the_queue_is_full()
  local host = FakeAudioOutput.new()
  local source = host.audio.newQueueableSource(SAMPLE_RATE, BIT_DEPTH, CHANNELS, 2)
  Assert.equal(source.bufferCount, 2, "the source must carry its explicit buffer count")
  Assert.equal(source:getFreeBufferCount(), 2)
  Assert.isTrue(source:queue(host.sound.newSoundData(4, SAMPLE_RATE, BIT_DEPTH, CHANNELS)))
  Assert.isTrue(source:queue(host.sound.newSoundData(4, SAMPLE_RATE, BIT_DEPTH, CHANNELS)))
  Assert.equal(source:getFreeBufferCount(), 0, "a full queue has no free buffers")
  Assert.isFalse(
    source:queue(host.sound.newSoundData(4, SAMPLE_RATE, BIT_DEPTH, CHANNELS)),
    "a full queue is refused with a false return, never a silent acceptance"
  )
  Assert.equal(#host.chunks, 2, "a refused chunk must not be recorded as delivered")
end

-- A queueable source constructed without an explicit buffer count is the
-- contract violation the acceptance double must reject loudly: omitting it
-- would silently adopt the real host's default queue depth as an accidental
-- latency policy.
function T.a_queueable_source_requires_an_explicit_buffer_count()
  local host = FakeAudioOutput.new()
  Assert.throws(function()
    host.audio.newQueueableSource(SAMPLE_RATE, BIT_DEPTH, CHANNELS)
  end, "omitting the buffer count must raise instead of adopting the host default")
end

-- While the source plays, the host playback head returns finished buffers to
-- the free pool: getFreeBufferCount drains one queued buffer per query, the
-- recording equivalent of the real host's audio thread freeing played buffers.
-- A stopped source keeps its queue: the full queue advertises no free buffers
-- (and refuses) instead of draining.
function T.the_playback_head_drains_queued_buffers_while_playing()
  local host = FakeAudioOutput.new()
  local source = host.audio.newQueueableSource(SAMPLE_RATE, BIT_DEPTH, CHANNELS, 2)
  local chunk = host.sound.newSoundData(4, SAMPLE_RATE, BIT_DEPTH, CHANNELS)
  source:queue(chunk)
  source:queue(chunk)
  source:play()
  Assert.equal(source:getFreeBufferCount(), 1, "a playing host head frees one buffer per free-count query")
  local stopped = host.audio.newQueueableSource(SAMPLE_RATE, BIT_DEPTH, CHANNELS, 2)
  stopped:queue(chunk)
  stopped:queue(chunk)
  Assert.equal(stopped:getFreeBufferCount(), 0, "a stopped full queue advertises no free buffers")
  Assert.isFalse(stopped:queue(chunk), "a stopped full queue refuses without draining")
end

function T.sound_data_shaped_chunks_are_accepted_and_the_non_silence_probes_read_them()
  local host = FakeAudioOutput.new()
  local source = host.audio.newQueueableSource(SAMPLE_RATE, BIT_DEPTH, CHANNELS, 3)
  Assert.equal(source.sampleRate, SAMPLE_RATE)
  Assert.equal(source.bitDepth, BIT_DEPTH)
  Assert.equal(source.channels, CHANNELS)

  local chunk = host.sound.newSoundData(4, SAMPLE_RATE, BIT_DEPTH, CHANNELS)
  Assert.equal(chunk:getSampleRate(), SAMPLE_RATE)
  Assert.equal(chunk:getBitDepth(), BIT_DEPTH)
  Assert.equal(chunk:getChannelCount(), CHANNELS)
  Assert.equal(chunk:getSampleCount(), 4, "the frame count per channel")
  chunk:setSample(0, 1, 0.5)
  chunk:setSample(0, 2, -0.5)
  source:queue(chunk)
  Assert.isTrue(host:anyNonSilent(), "the queued SoundData must drive the non-silence probe")

  source:queue(host.sound.newSoundData(4, SAMPLE_RATE, BIT_DEPTH, CHANNELS))
  source:queue(host.sound.newSoundData(4, SAMPLE_RATE, BIT_DEPTH, CHANNELS))
  Assert.equal(host:silentChunksSinceLastNonSilent(), 2)
end

return { tests = T }
