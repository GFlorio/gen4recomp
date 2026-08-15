-- The one authoritative cross-file bundle/reference walk for the derived
-- audio cache: index -> sequence -> bank -> sample metadata -> payload. Both
-- AudioCache.isReady and AudioCacheWriter's staged readback run this walk, so
-- readiness and the write gate can never drift apart; there is no second
-- inspection vocabulary. The walk is content-only: it returns nil when the
-- cache is valid or a problem message otherwise, never raises (the leaf
-- validators' structured errors are converted into problems). The completion
-- marker is the caller's business (isReady checks it first; the writer writes
-- it last). Pure domain module.

local AudioCache = require("libs.assets.src.AudioCache")
local AudioSequence = require("libs.assets.src.AudioSequence")
local AudioBank = require("libs.assets.src.AudioBank")
local AudioSample = require("libs.assets.src.AudioSample")

local AudioCacheValidator = {}

-- Runs a leaf validator that raises on malformed assets, reporting failure as
-- a problem instead of propagating.
---@param validate fun(...): boolean
---@return boolean
local function passes(validate, ...)
  local ok = pcall(validate, ...)
  return ok
end

---@param cacheFs CacheFs
---@return string|nil
function AudioCacheValidator.validate(cacheFs)
  local index = cacheFs:loadLua(AudioCache.indexPath())
  if type(index) ~= "table" or index.schema ~= AudioCache.INDEX_SCHEMA then
    return "index is missing or carries an unexpected schema"
  end
  if
    type(index.sequences) ~= "table"
    or type(index.banks) ~= "table"
    or type(index.sequenceBySymbol) ~= "table"
    or type(index.bankBySymbol) ~= "table"
  then
    return "index sections are missing"
  end
  for id, entry in pairs(index.sequences) do
    if type(id) ~= "number" or id < 0 or id % 1 ~= 0 or type(entry) ~= "table" or entry.id ~= id then
      return "sequence index entry is malformed"
    end
    if type(entry.bankId) ~= "number" or index.banks[entry.bankId] == nil then
      return "sequence bank id does not resolve"
    end
    local sequence = cacheFs:loadLua(AudioCache.sequencePath(id))
    if type(sequence) ~= "table" then
      return "sequence asset is missing or unreadable"
    end
    if not passes(AudioSequence.validate, sequence) then
      return "sequence fails its validator"
    end
    if sequence.id ~= entry.id then
      return "sequence identity does not match its index entry"
    end
  end
  for id, entry in pairs(index.banks) do
    if type(id) ~= "number" or id < 0 or id % 1 ~= 0 or type(entry) ~= "table" or entry.id ~= id then
      return "bank index entry is malformed"
    end
    local bank = cacheFs:loadLua(AudioCache.bankPath(id))
    if type(bank) ~= "table" then
      return "bank asset is missing or unreadable"
    end
    if not passes(AudioBank.validate, bank) then
      return "bank fails its validator"
    end
    if bank.id ~= entry.id then
      return "bank identity does not match its index entry"
    end
    local keys = AudioBank.sampleKeys(bank)
    assert(keys, "a validated bank always exposes its sample references")
    for _, key in ipairs(keys) do
      local metadata = cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
      if type(metadata) ~= "table" then
        return "referenced sample metadata is missing or unreadable"
      end
      local payload = cacheFs:read(AudioCache.samplePath(key))
      if payload == nil then
        return "referenced sample payload is missing"
      end
      if not passes(AudioSample.validate, metadata, payload) then
        return "sample metadata or payload fails its validator"
      end
      if metadata.key ~= key then
        return "sample metadata key does not match its address"
      end
    end
  end
  return nil
end

return AudioCacheValidator
