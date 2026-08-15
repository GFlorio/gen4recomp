-- AudioSample validator contract: sample metadata is content-addressed by a
-- sha1 key that doubles as its path identity, points at the canonical PCM16LE
-- payload path, and carries engine-meaningful timing (frames, sampleRate,
-- loop frames) — never raw SWAV units.

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

function T.schema_constant_follows_the_contract()
  Assert.equal(AudioSample.SCHEMA, DerivedAssetContract.audio.sampleSchema)
end

function T.accepts_well_formed_metadata()
  Assert.isTrue(AudioSample.validate(AudioFixture.sampleMetadata(AudioFixture.key(1))))
end

function T.validates_schema_and_content_key()
  local metadata = AudioFixture.sampleMetadata(AudioFixture.key(1))
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

function T.payload_path_is_the_canonical_content_address()
  local metadata = AudioFixture.sampleMetadata(AudioFixture.key(1))
  metadata.file = nil
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.file = "data/generated/audio/samples/elsewhere.pcm16le"
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
  metadata.file = AudioCache.samplePath(AudioFixture.key(1))
  Assert.isTrue(AudioSample.validate(metadata), "the payload path is derived from the content key")
end

function T.validates_frames_and_sample_rate()
  local metadata = AudioFixture.sampleMetadata(AudioFixture.key(1))
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
  metadata.frames = 8214
  metadata.sampleRate = 0
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    AudioSample.validate(metadata)
  end)
end

function T.validates_the_loop_frame_window()
  local metadata = AudioFixture.sampleMetadata(AudioFixture.key(1))
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
  local metadata = AudioFixture.sampleMetadata(AudioFixture.key(1))
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
