-- Persists the derived audio class through the shared staged publication
-- primitive: the provenance record, the index, one file per indexed sequence
-- and bank, and unique content-addressed sample payloads with their metadata
-- are written into a disposable staging root, readback-validated there by the
-- one authoritative cross-file walk (AudioCacheValidator, the same rule
-- AudioCache.isReady runs), and only then is the completed stage published
-- with the marker last. Staging and validation are one step; publication
-- happens outside that step's error handler, so a publish failure never
-- triggers writer-level stage cleanup that could delete the last remaining
-- copy of the previous artifact.

local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.AudioCache")
local AudioCacheValidator = require("libs.assets.src.AudioCacheValidator")
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
  -- Readback is the same authoritative cross-file walk readiness runs; a
  -- problem fails the staged write before anything is published.
  local problem = AudioCacheValidator.validate(stage)
  if problem ~= nil then
    raiseReadback(problem, {})
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
