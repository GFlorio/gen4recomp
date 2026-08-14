-- Paths, contract constants, and strict readiness for the derived audio cache.
-- The audio class (index, sequence/bank assets, content-addressed samples)
-- is one of the independently rebuildable derived classes: changing the
-- sound-archive compiler must not disturb the raw ROM dump or any other
-- class. Readiness verifies more than the completion marker: the exact
-- marker, the index schema, every indexed sequence and bank with matching
-- schema and identity, sequence bank-id resolution, and every
-- bank-referenced sample's metadata and PCM payload. A missing artifact is
-- never interpreted as silence. Paths are cache-relative; all IO goes
-- through a CacheFs.

local AudioCache = {}

local Validate = require("libs.assets.src.Validate")
local AudioBank = require("libs.assets.src.AudioBank")
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

-- True only if the marker is exact, the index loads with the expected schema,
-- every indexed sequence file carries the expected schema and matching
-- identity and its bank id resolves into the index, every indexed bank file
-- carries the expected schema and matching identity, and every sample key a
-- bank references has both its metadata file (with the expected schema and a
-- key matching its address) and its PCM payload.
function AudioCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(AudioCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(AudioCache.indexPath())
  if type(index) ~= "table" or index.schema ~= AudioCache.INDEX_SCHEMA then
    return false
  end
  if type(index.sequences) ~= "table" or type(index.banks) ~= "table" then
    return false
  end
  for id, entry in pairs(index.sequences) do
    if
      type(id) ~= "number"
      or id < 0
      or id % 1 ~= 0
      or type(entry) ~= "table"
      or entry.id ~= id
      or type(entry.bankId) ~= "number"
      or index.banks[entry.bankId] == nil
    then
      return false
    end
    local sequence = cacheFs:loadLua(AudioCache.sequencePath(id))
    if type(sequence) ~= "table" or sequence.schema ~= AudioCache.SEQUENCE_SCHEMA or sequence.id ~= entry.id then
      return false
    end
  end
  for id, entry in pairs(index.banks) do
    if type(id) ~= "number" or id < 0 or id % 1 ~= 0 or type(entry) ~= "table" or entry.id ~= id then
      return false
    end
    local bank = cacheFs:loadLua(AudioCache.bankPath(id))
    if type(bank) ~= "table" or bank.schema ~= AudioCache.BANK_SCHEMA or bank.id ~= entry.id then
      return false
    end
    local keys = AudioBank.sampleKeys(bank)
    if keys == nil then
      return false
    end
    for _, key in ipairs(keys) do
      local metadata = cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
      if type(metadata) ~= "table" or metadata.schema ~= AudioCache.SAMPLE_SCHEMA or metadata.key ~= key then
        return false
      end
      if not cacheFs:exists(AudioCache.samplePath(key), "file") then
        return false
      end
    end
  end
  return true
end

return AudioCache
