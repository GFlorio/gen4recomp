-- Persists a compiled field-message bundle through the shared staged
-- publication primitive: the provenance record, the index, and one file per
-- selected bank are written into a disposable staging root, readback-validated
-- there, and only then is the completed stage published with the marker last.
-- Staging and validation are one step; publication happens outside that step's
-- error handler, so a publish failure never triggers writer-level stage
-- cleanup that could delete the last remaining copy of the previous artifact.

local Errors = require("libs.errors.src.Errors")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local FieldMessageCacheWriter = {}

function FieldMessageCacheWriter.isReady(cacheFs, marker)
  return FieldMessageCache.isReady(cacheFs, marker)
end

local function stageBundle(tx, bundle)
  local stage = tx.stage
  stage:writeLua(FieldMessageCache.provenancePath(), {
    schema = FieldMessageCache.PROVENANCE_SCHEMA,
    dependencies = bundle.dependencies,
  })
  stage:writeLua(FieldMessageCache.indexPath(), bundle.index)
  for _, bankId in ipairs(bundle.index.bankIds) do
    local bank = bundle.banks[bankId]
    assert(bank and bank.schema == FieldMessageCache.SCHEMA, "bundle is missing bank " .. tostring(bankId))
    stage:writeLua(FieldMessageCache.bankPath(bankId), bank)
  end
  local readIndex = stage:loadLua(FieldMessageCache.indexPath())
  if type(readIndex) ~= "table" or readIndex.schema ~= FieldMessageCache.INDEX_SCHEMA then
    Errors.raise("FIELD_MESSAGE_CACHE_READBACK_FAILED", "index readback failed", {})
  end
  for _, bankId in ipairs(bundle.index.bankIds) do
    local bank = stage:loadLua(FieldMessageCache.bankPath(bankId))
    if type(bank) ~= "table" or bank.schema ~= FieldMessageCache.SCHEMA or bank.bankId ~= bankId then
      Errors.raise(
        "FIELD_MESSAGE_CACHE_READBACK_FAILED",
        "bank " .. tostring(bankId) .. " readback failed",
        { bankId = bankId }
      )
    end
  end
  stage:write(FieldMessageCache.markerPath(), bundle.marker)
end

function FieldMessageCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.index and bundle.banks, "write requires a message bundle")
  assert(bundle.index.schema == FieldMessageCache.INDEX_SCHEMA, "bundle index schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "field-messages", { FieldMessageCache.dir() })
  local ok, err = pcall(stageBundle, tx, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return FieldMessageCacheWriter
