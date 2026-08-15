-- AudioCache contract: the g4-audio cache layout, the contract constants,
-- and the strict-readiness gate. Readiness verifies the exact marker and the
-- authoritative cross-file walk (AudioCacheValidator): the index schema and
-- sections, every indexed sequence/bank file with its leaf validator passing
-- and its identity matching, sequence bank-id resolution, and every
-- bank-referenced sample's metadata and PCM payload. A missing artifact is
-- never silence.

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.AudioCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local AudioFixture = require("tests.support.AudioFixture")

local T = {}

function T.constants_and_layout_paths_follow_the_contract()
  Assert.equal(AudioCache.FORMAT, DerivedAssetContract.audio.cacheFormat)
  Assert.equal(AudioCache.INDEX_SCHEMA, DerivedAssetContract.audio.indexSchema)
  Assert.equal(AudioCache.SEQUENCE_SCHEMA, DerivedAssetContract.audio.sequenceSchema)
  Assert.equal(AudioCache.BANK_SCHEMA, DerivedAssetContract.audio.bankSchema)
  Assert.equal(AudioCache.SAMPLE_SCHEMA, DerivedAssetContract.audio.sampleSchema)
  Assert.equal(AudioCache.PROVENANCE_SCHEMA, DerivedAssetContract.audio.provenanceSchema)
  Assert.equal(AudioCache.dir(), "data/generated/audio")
  Assert.equal(AudioCache.indexPath(), "data/generated/audio/index.lua")
  Assert.equal(AudioCache.provenancePath(), "data/generated/audio/provenance.lua")
  Assert.equal(AudioCache.markerPath(), "data/generated/audio/complete")
  Assert.equal(AudioCache.sequencePath(0), "data/generated/audio/sequences/0000.lua")
  Assert.equal(AudioCache.sequencePath(37), "data/generated/audio/sequences/0037.lua")
  Assert.equal(AudioCache.bankPath(12), "data/generated/audio/banks/0012.lua")
  local key = AudioFixture.key(1)
  Assert.equal(AudioCache.samplePath(key), "data/generated/audio/samples/" .. key .. ".pcm16le")
  Assert.equal(AudioCache.sampleMetadataPath(key), "data/generated/audio/sample-metadata/" .. key .. ".lua")
end

function T.marker_combines_format_rom_and_dependency_identity()
  Assert.equal(AudioCache.marker("rom-sha", "dep-sha"), "g4-audio-cache-v1:rom-sha:dep-sha")
end

function T.valid_artifact_is_ready()
  local cache = AudioFixture.readyCache()
  Assert.isTrue(AudioCache.isReady(cache, AudioCache.marker("rom-sha", "dep-sha")))
end

function T.marker_mismatch_is_not_ready()
  local cache = AudioFixture.readyCache()
  Assert.isFalse(AudioCache.isReady(cache, AudioCache.marker("other-rom", "dep-sha")), "marker must match exactly")
end

function T.missing_marker_is_not_ready()
  local cache = AudioFixture.readyCache()
  cache:remove(AudioCache.markerPath())
  Assert.isFalse(AudioCache.isReady(cache, AudioCache.marker("rom-sha", "dep-sha")))
end

function T.index_schema_mismatch_is_not_ready()
  local bundle = AudioFixture.bundle()
  bundle.index.schema = "g4-audio-index-v9"
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker))
end

function T.missing_indexed_sequence_is_not_ready()
  local bundle = AudioFixture.bundle()
  local cache = AudioFixture.readyCache(bundle)
  cache:remove(AudioCache.sequencePath(37))
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "every indexed sequence must exist")
end

function T.sequence_with_wrong_schema_is_not_ready()
  local bundle = AudioFixture.bundle()
  bundle.sequences[0].schema = "g4-audio-sequence-v9"
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "indexed sequence must carry the expected schema")
end

function T.sequence_with_wrong_identity_is_not_ready()
  local bundle = AudioFixture.bundle()
  bundle.sequences[0].id = 5
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "sequence file identity must match its index entry")
end

function T.sequence_with_unresolved_bank_id_is_not_ready()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[37].bankId = 99
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "sequence bank ids must resolve into the index")
end

function T.negative_indexed_ids_are_not_ready()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[-1] = { id = -1, bankId = 12 }
  bundle.sequences[-1] = AudioFixture.sequence(-1, nil, 12, 1)
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "ids become path components; negatives are malformed")
end

function T.missing_indexed_bank_is_not_ready()
  local bundle = AudioFixture.bundle()
  local cache = AudioFixture.readyCache(bundle)
  cache:remove(AudioCache.bankPath(12))
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "every indexed bank must exist")
end

function T.bank_with_wrong_identity_is_not_ready()
  local bundle = AudioFixture.bundle()
  bundle.banks[12].id = 13
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "bank file identity must match its index entry")
end

function T.missing_referenced_sample_metadata_is_not_ready()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  local cache = AudioFixture.readyCache(bundle)
  cache:remove(AudioCache.sampleMetadataPath(key))
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "every bank-referenced sample needs its metadata")
end

function T.sample_metadata_with_wrong_key_is_not_ready()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  bundle.sampleMetadata[key].key = AudioFixture.key(2)
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "sample metadata key must match its address")
end

function T.sample_metadata_without_pcm_payload_is_not_ready()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  local cache = AudioFixture.readyCache(bundle)
  cache:remove(AudioCache.samplePath(key))
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "every sample metadata record needs its payload")
end

function T.bank_sample_reference_without_metadata_is_not_ready()
  local bundle = AudioFixture.bundle()
  bundle.banks[12].instruments[0].voice.generator.sample = AudioFixture.key(99)
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "bank sample ids must resolve into sample metadata")
end

-- Readiness runs the authoritative asset validators, never a weaker
-- presence-only or shape-walk-only check: content that fails its validator
-- is not ready even when every referenced file exists and every reference
-- resolves.
function T.sequence_content_failing_its_validator_is_not_ready()
  local bundle = AudioFixture.bundle()
  bundle.sequences[0].program = nil
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "an indexed sequence must pass its validator")
end

function T.bank_content_failing_its_validator_is_not_ready()
  local bundle = AudioFixture.bundle()
  bundle.banks[12].instruments[0].voice.envelope.attack = 0xFFFF
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "an indexed bank must pass its validator")
end

function T.sample_payload_with_wrong_byte_count_is_not_ready()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  bundle.samples[key] = bundle.samples[key] .. "\0"
  local cache = AudioFixture.readyCache(bundle)
  Assert.isFalse(AudioCache.isReady(cache, bundle.marker), "payload byte count must match the metadata frames")
end

return { tests = T }
