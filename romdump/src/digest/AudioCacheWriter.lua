-- Persists the derived audio class through the shared staged publication
-- primitive: the provenance record, the index, one file per indexed sequence
-- and bank, and unique content-addressed sample payloads with their metadata
-- are written into a disposable staging root, readback-validated there (the
-- asset validators plus reference resolution), and only then is the completed
-- stage published with the marker last. Staging and validation are one step;
-- publication happens outside that step's error handler, so a publish failure
-- never triggers writer-level stage cleanup that could delete the last
-- remaining copy of the previous artifact.

local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.AudioCache")
local AudioSequence = require("libs.assets.src.AudioSequence")
local AudioBank = require("libs.assets.src.AudioBank")
local AudioSample = require("libs.assets.src.AudioSample")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local AudioCacheWriter = {}

function AudioCacheWriter.isReady(cacheFs, marker)
  return AudioCache.isReady(cacheFs, marker)
end

local function raiseReadback(message, context)
  Errors.raise("AUDIO_CACHE_READBACK_FAILED", message, context)
end

local function stageBundle(tx, bundle)
  local stage = tx.stage
  stage:writeLua(AudioCache.provenancePath(), {
    schema = AudioCache.PROVENANCE_SCHEMA,
    dependencies = bundle.dependencies,
  })
  stage:writeLua(AudioCache.indexPath(), bundle.index)
  for id, _ in pairs(bundle.index.sequences) do
    local sequence = bundle.sequences[id]
    assert(sequence, "bundle is missing sequence " .. tostring(id))
    stage:writeLua(AudioCache.sequencePath(id), sequence)
  end
  for id, _ in pairs(bundle.index.banks) do
    local bank = bundle.banks[id]
    assert(bank, "bundle is missing bank " .. tostring(id))
    stage:writeLua(AudioCache.bankPath(id), bank)
  end
  for key, bytes in pairs(bundle.samples) do
    assert(bundle.sampleMetadata[key] ~= nil, "bundle is missing sample metadata for " .. tostring(key))
    stage:write(AudioCache.samplePath(key), bytes)
    stage:writeLua(AudioCache.sampleMetadataPath(key), bundle.sampleMetadata[key])
  end
  local readIndex = stage:loadLua(AudioCache.indexPath())
  if type(readIndex) ~= "table" or readIndex.schema ~= AudioCache.INDEX_SCHEMA then
    raiseReadback("index readback failed", {})
  end
  if type(readIndex.sequences) ~= "table" or type(readIndex.banks) ~= "table" then
    raiseReadback("index sections missing", {})
  end
  for id, entry in pairs(readIndex.sequences) do
    local sequence = stage:loadLua(AudioCache.sequencePath(id))
    if type(sequence) ~= "table" then
      raiseReadback("sequence readback failed", { sequenceId = id })
    end
    AudioSequence.validate(sequence)
    if sequence.id ~= entry.id then
      raiseReadback("sequence identity mismatch", { sequenceId = id })
    end
    if readIndex.banks[entry.bankId] == nil then
      raiseReadback("sequence bank id does not resolve", { sequenceId = id, bankId = entry.bankId })
    end
  end
  for id, entry in pairs(readIndex.banks) do
    local bank = stage:loadLua(AudioCache.bankPath(id))
    if type(bank) ~= "table" then
      raiseReadback("bank readback failed", { bankId = id })
    end
    AudioBank.validate(bank)
    if bank.id ~= entry.id then
      raiseReadback("bank identity mismatch", { bankId = id })
    end
    local keys = AudioBank.sampleKeys(bank)
    assert(keys, "a validated bank always exposes its sample references")
    for _, key in ipairs(keys) do
      local metadata = stage:loadLua(AudioCache.sampleMetadataPath(key))
      if type(metadata) ~= "table" then
        raiseReadback("referenced sample metadata is missing", { key = key, bankId = id })
      end
      if stage:read(AudioCache.samplePath(key)) == nil then
        raiseReadback("sample payload is missing", { key = key, bankId = id })
      end
    end
  end
  for key, _ in pairs(bundle.sampleMetadata) do
    local metadata = stage:loadLua(AudioCache.sampleMetadataPath(key))
    if type(metadata) ~= "table" then
      raiseReadback("sample metadata readback failed", { key = key })
    end
    local payload = stage:read(AudioCache.samplePath(key))
    if payload == nil then
      raiseReadback("sample payload is missing", { key = key })
    end
    AudioSample.validate(metadata, payload)
    if metadata.key ~= key then
      raiseReadback("sample metadata key does not match its address", { key = key })
    end
  end
  stage:write(AudioCache.markerPath(), bundle.marker)
end

function AudioCacheWriter.write(cacheFs, bundle)
  assert(bundle, "write requires an audio bundle")
  assert(bundle.marker, "marker is a required bundle section")
  assert(bundle.index, "index is a required bundle section")
  assert(bundle.sequences, "sequences is a required bundle section")
  assert(bundle.banks, "banks is a required bundle section")
  assert(bundle.samples, "samples is a required bundle section")
  assert(bundle.sampleMetadata, "sampleMetadata is a required bundle section")
  assert(bundle.dependencies, "dependencies is a required bundle section")
  assert(type(bundle.index.sequences) == "table", "index.sequences is a required bundle section")
  assert(type(bundle.index.banks) == "table", "index.banks is a required bundle section")
  assert(bundle.index.schema == AudioCache.INDEX_SCHEMA, "bundle index schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "audio", { AudioCache.dir() })
  local ok, err = pcall(stageBundle, tx, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return AudioCacheWriter
