-- AudioSample validator contract: sample metadata is content-addressed by a
-- sha1 key that doubles as its path identity, and carries engine-meaningful
-- timing only -- frames, the SWAV base timer, the loop flag, and the loop
-- window. The source sample rate never enters the derived shape (playback
-- derives from the DS sound clock and the calculated timer), and the payload
-- path is not stored (it is deterministically derived from the key), so
-- either field is malformed. The exact payload size (#pcm == frames * 2) is
-- part of the contract: load/readback paths validate the metadata together
-- with the payload bytes.

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.AudioCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local AudioSample = require("libs.assets.src.AudioSample")
local AudioFixture = require("tests.support.AudioFixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(err.code ~= nil, "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

-- The pinned derived shape: schema, key, frames, baseTimer, loopEnabled,
-- loop -- and nothing else. `opts` overrides frames/baseTimer/loop/
-- loopEnabled so tests can pin a wave's timer, loop flag, and loop window.
-- One-shot waves (loopEnabled false) must carry the full-range window,
-- mirroring the compiler's normalization.
local function sampleMetadata(key, opts)
  opts = opts or {}
  local frames = opts.frames or 8214
  local loop = opts.loop or { startFrame = 0, endFrame = frames }
  return {
    schema = AudioCache.SAMPLE_SCHEMA,
    key = key,
    frames = frames,
    baseTimer = opts.baseTimer or 8006,
    loopEnabled = opts.loopEnabled ~= false,
    loop = loop,
  }
end

function T.schema_constant_follows_the_contract()
  Assert.equal(AudioSample.SCHEMA, DerivedAssetContract.audio.sampleSchema)
end

-- The runtime-relevant shape is exactly schema/key/frames/baseTimer/loop:
-- no source rate, no stored payload path.
function T.accepts_metadata_without_rate_or_payload_path()
  Assert.isTrue(
    AudioSample.validate(sampleMetadata(AudioFixture.key(1))),
    "the derived shape carries no sampleRate and no file field"
  )
end

-- The removed fields are rejected, not ignored: a source sample rate or a
-- stored payload path is malformed metadata under the strict schema.
function T.rejects_source_rate_and_payload_path_fields()
  local metadata = sampleMetadata(AudioFixture.key(1))
  metadata.sampleRate = 32768
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.sampleRate = nil
  metadata.file = AudioCache.samplePath(AudioFixture.key(1))
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
end

function T.validates_schema_and_content_key()
  local metadata = sampleMetadata(AudioFixture.key(1))
  metadata.schema = nil
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.schema = "g4-audio-sample-v9"
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.schema = AudioSample.SCHEMA
  metadata.key = nil
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.key = "not-a-sha1"
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.key = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
end

function T.validates_frames()
  local metadata = sampleMetadata(AudioFixture.key(1))
  metadata.frames = nil
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.frames = 8214.5
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.frames = -1
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
end

-- The SWAV base timer is preserved as a semantic field: it must be a positive
-- integer in the source u16 range. Zero (an invalid DS rate) and out-of-range
-- values are malformed metadata.
function T.validates_the_base_timer()
  local metadata = sampleMetadata(AudioFixture.key(1))
  metadata.baseTimer = nil
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.baseTimer = 0
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.baseTimer = -1
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.baseTimer = 1.5
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.baseTimer = 0x10000
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.baseTimer = 759
  Assert.isTrue(AudioSample.validate(metadata), "a valid source timer is accepted")
end

-- The payload size contract: PCM16LE is exactly two bytes per frame, so a
-- metadata record whose payload is missing, odd, or has the wrong frame count
-- is malformed when validated together with its payload bytes.
function T.validates_the_exact_payload_size()
  local metadata = sampleMetadata(AudioFixture.key(1), { frames = 4 })
  local payload = AudioFixture.pcm16le({ 1, 2, 3, 4 })
  Assert.isTrue(AudioSample.validate(metadata, payload), "frames*2 bytes of PCM16LE is valid")

  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata, payload .. "\0")
  end)
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata, payload:sub(1, -2))
  end)
  metadata.frames = 5
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata, payload)
  end)
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata, 12345)
  end)
  metadata.frames = 4
  Assert.isTrue(AudioSample.validate(metadata, payload))
end

function T.validates_the_loop_frame_window()
  local metadata = sampleMetadata(AudioFixture.key(1))
  metadata.loop = nil
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.loop = { startFrame = 0, endFrame = 9000 }
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.loop = { startFrame = 100, endFrame = 100 }
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.loop = { startFrame = -1, endFrame = 100 }
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.loop = { startFrame = 0, endFrame = 8214 }
  Assert.isTrue(AudioSample.validate(metadata), "a loop ending on the last frame is valid")
end

function T.validates_the_loop_flag()
  local metadata = sampleMetadata(AudioFixture.key(1))
  metadata.loopEnabled = nil
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.loopEnabled = 1
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  -- One-shot waves always carry the full-range window; the flag owns the
  -- one-shot/loop distinction.
  metadata.loopEnabled = false
  metadata.loop = { startFrame = 100, endFrame = 8214 }
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.loop = { startFrame = 0, endFrame = 8214 }
  Assert.isTrue(AudioSample.validate(metadata), "a one-shot wave with the full-range window is valid")
end

return { tests = T }
