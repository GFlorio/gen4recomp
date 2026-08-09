-- Atomic marker-last writer for the field-message derived class. Writes the
-- provenance record, the index, and one file per selected bank, readback-
-- validates the index and every bank file, and only then publishes the
-- completion marker. On any failure the whole class is invalidated so a
-- partial build never reads as complete.

local Errors = require("libs.rom.src.Errors")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")

local FieldMessageCacheWriter = {}

function FieldMessageCacheWriter.isReady(cacheFs, marker)
  return FieldMessageCache.isReady(cacheFs, marker)
end

function FieldMessageCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.index and bundle.banks, "write requires a message bundle")
  assert(bundle.index.schema == FieldMessageCache.INDEX_SCHEMA, "bundle index schema mismatch")
  local ok, err = pcall(function()
    cacheFs:remove(FieldMessageCache.markerPath())
    cacheFs:writeLua(FieldMessageCache.provenancePath(), {
      schema = FieldMessageCache.PROVENANCE_SCHEMA,
      dependencies = bundle.dependencies,
    })
    cacheFs:writeLua(FieldMessageCache.indexPath(), bundle.index)
    for _, bankId in ipairs(bundle.index.bankIds) do
      local bank = bundle.banks[bankId]
      assert(bank and bank.schema == FieldMessageCache.SCHEMA, "bundle is missing bank " .. tostring(bankId))
      cacheFs:writeLua(FieldMessageCache.bankPath(bankId), bank)
    end
    local readIndex = cacheFs:loadLua(FieldMessageCache.indexPath())
    if type(readIndex) ~= "table" or readIndex.schema ~= FieldMessageCache.INDEX_SCHEMA then
      Errors.raise("FIELD_MESSAGE_CACHE_READBACK_FAILED", "index readback failed", {})
    end
    for _, bankId in ipairs(bundle.index.bankIds) do
      local bank = cacheFs:loadLua(FieldMessageCache.bankPath(bankId))
      if type(bank) ~= "table" or bank.schema ~= FieldMessageCache.SCHEMA or bank.bankId ~= bankId then
        Errors.raise(
          "FIELD_MESSAGE_CACHE_READBACK_FAILED",
          "bank " .. tostring(bankId) .. " readback failed",
          { bankId = bankId }
        )
      end
    end
    cacheFs:write(FieldMessageCache.markerPath(), bundle.marker)
  end)
  if ok then
    return true
  end
  pcall(function()
    FieldMessageCache.invalidate(cacheFs)
  end)
  error(err)
end

return FieldMessageCacheWriter
