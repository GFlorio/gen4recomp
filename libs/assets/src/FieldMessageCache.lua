-- Readiness, paths, and invalidation for the derived field-message cache.
-- Message banks are one of the independently rebuildable derived classes (map
-- geometry, actor visuals, messages/font): changing the message compiler must
-- not disturb the raw ROM dump or any compiled map. A bank is ready only when
-- the completion marker matches exactly and every bank file it indexes is
-- present, so a partial build never reads as complete. Paths are
-- cache-relative; all IO goes through a CacheFs.

local FieldMessageCache = {}

FieldMessageCache.FORMAT = "field-message-cache-v1"
FieldMessageCache.SCHEMA = "g4-field-message-bank-v1"
FieldMessageCache.INDEX_SCHEMA = "g4-field-message-index-v1"
FieldMessageCache.PROVENANCE_SCHEMA = "g4-field-message-provenance-v1"

local DATA_DIR = "data/generated/field/messages"

function FieldMessageCache.dir() return DATA_DIR end
function FieldMessageCache.indexPath() return DATA_DIR .. "/index.lua" end
function FieldMessageCache.provenancePath() return DATA_DIR .. "/provenance.lua" end
function FieldMessageCache.markerPath() return DATA_DIR .. "/complete" end

function FieldMessageCache.bankPath(bankId)
  return string.format("%s/banks/%04d.lua", DATA_DIR, bankId)
end

function FieldMessageCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldMessageCache.FORMAT, romSha1, depHash)
end

-- True only if the marker is exact, the index loads with the expected schema,
-- and every indexed bank's file is present.
function FieldMessageCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldMessageCache.markerPath()) ~= expectedMarker then return false end
  local index = cacheFs:loadLua(FieldMessageCache.indexPath())
  if type(index) ~= "table" or index.schema ~= FieldMessageCache.INDEX_SCHEMA then return false end
  for _, bankId in ipairs(index.bankIds or {}) do
    if not cacheFs:exists(FieldMessageCache.bankPath(bankId), "file") then return false end
  end
  return true
end

function FieldMessageCache.invalidate(cacheFs)
  assert(DATA_DIR:find("generated", 1, true), "derived root must live under a generated subtree")
  cacheFs:removeTree(DATA_DIR)
  return true
end

return FieldMessageCache
