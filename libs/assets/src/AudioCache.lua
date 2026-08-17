-- Paths, contract constants, and strict readiness for the derived audio cache.
-- The audio class shares the per-version derived-cache identity with every
-- other derived class (the build-state identity includes the whole
-- DerivedAssetContract), so a sound-archive compiler change alone never
-- disturbs the raw ROM dump, and an audio contract change is not rebuildable
-- in isolation from the other classes. Readiness verifies more than the
-- completion marker: the exact marker and the authoritative cross-file walk
-- (AudioCacheValidator) over the index (schema and every runtime-required
-- section), every indexed sequence and bank (schema, identity, and index
-- agreement), and every bank-referenced sample's metadata and PCM payload. A
-- missing artifact is never interpreted as silence. Paths are
-- cache-relative; all IO goes through a CacheFs.

local AudioCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")

AudioCache.FORMAT = Contract.audio.cacheFormat
AudioCache.INDEX_SCHEMA = Contract.audio.indexSchema
AudioCache.SEQUENCE_SCHEMA = Contract.audio.sequenceSchema
AudioCache.BANK_SCHEMA = Contract.audio.bankSchema
AudioCache.SAMPLE_SCHEMA = Contract.audio.sampleSchema
AudioCache.PROVENANCE_SCHEMA = Contract.audio.provenanceSchema

local DATA_DIR = "data/generated/audio"

function AudioCache.dir()
  return DATA_DIR
end
function AudioCache.indexPath()
  return DATA_DIR .. "/index.lua"
end
function AudioCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function AudioCache.markerPath()
  return DATA_DIR .. "/complete"
end

function AudioCache.sequencePath(id)
  return string.format("%s/sequences/%04d.lua", DATA_DIR, id)
end

function AudioCache.bankPath(id)
  return string.format("%s/banks/%04d.lua", DATA_DIR, id)
end

function AudioCache.samplePath(key)
  return string.format("%s/samples/%s.pcm16le", DATA_DIR, key)
end

function AudioCache.sampleMetadataPath(key)
  return string.format("%s/sample-metadata/%s.lua", DATA_DIR, key)
end

function AudioCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", AudioCache.FORMAT, romSha1, depHash)
end

-- True only if the marker is exact and the authoritative cross-file walk
-- (AudioCacheValidator) finds no problem: the index schema and every
-- runtime-required section (sequences, banks, players, both symbol maps),
-- player-record validity (supported id range, integer U16 channel mask,
-- positive slot count for used players), index records carrying no stored
-- payload path, every indexed sequence/bank asset with its validator passing
-- and its identity agreeing with the index, sequence bank-id and player-id
-- resolution, bidirectional symbol-map consistency, and every
-- bank-referenced sample's metadata (schema, address-matching key) and PCM
-- payload. The validator requires this module for its paths, so it is loaded
-- here rather than at module scope (the walk is never needed before isReady
-- runs).
function AudioCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(AudioCache.markerPath()) ~= expectedMarker then
    return false
  end
  return require("libs.assets.src.AudioCacheValidator").validate(cacheFs) == nil
end

return AudioCache
