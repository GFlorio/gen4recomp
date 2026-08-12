-- Keyed snapshot of the registry's derived fingerprint, persisted into the
-- script cache. The key covers the script-cache marker and the override
-- manifest plus every listed override file, so a matching key proves the
-- registry content is exactly what the stored fingerprint was computed from:
-- no re-validation or re-hashing on the fast path. Load never raises (any
-- anomaly is a miss that falls back to the slow validated build); save never
-- reports success after a failed write. Pure domain module: no love
-- dependency.

local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptLoader = require("libs.engine.src.script.ScriptLoader")
local Sha256 = require("libs.engine.src.script.Sha256")

local RegistrySnapshot = {}

RegistrySnapshot.SCHEMA = "g4-registry-snapshot-v1"
RegistrySnapshot.FILE = "data/generated/script/registry.lua"

local HEX_DIGEST = "^[0-9a-f]+$"

-- The current snapshot key: one digest over the script-cache marker and the
-- whole override tree (the manifest text plus every listed file, sorted by
-- id). The marker gates the generated corpus by build contract, and the
-- override bytes gate the checked-in layer, so the same key implies the same
-- registry content. nil when any input is unavailable: a broken cache or
-- override tree can never be snapshotted.
---@param cacheFs table CacheFs-shaped
---@param overrideFs table read-shaped filesystem for data/scripts/overrides
---@return string|nil
function RegistrySnapshot.key(cacheFs, overrideFs)
  local marker = cacheFs:read(ScriptCache.markerPath())
  if marker == nil then
    return nil
  end
  local manifest = overrideFs:read(ScriptLoader.OVERRIDE_MANIFEST)
  if manifest == nil then
    return nil
  end
  local chunk, loadErr = loadstring(manifest --[[@as string]], ScriptLoader.OVERRIDE_MANIFEST)
  if not chunk then
    return nil
  end
  local ok, ids = pcall(chunk)
  if not ok or type(ids) ~= "table" then
    return nil
  end
  local idsList = {}
  for index = 1, #ids do
    local id = ids[index]
    if type(id) ~= "string" or id == "" then
      return nil
    end
    idsList[#idsList + 1] = id
  end
  table.sort(idsList)
  local parts = { marker, "\n", manifest }
  for _, id in ipairs(idsList) do
    local content = overrideFs:read(ScriptLoader.OVERRIDES_DIR .. "/" .. id .. ".lua")
    if content == nil then
      return nil
    end
    parts[#parts + 1] = "\n"
    parts[#parts + 1] = content
  end
  return Sha256.hex(table.concat(parts))
end

---@param value any
---@return boolean
local function isHexDigest(value)
  return type(value) == "string" and #value == 64 and value:match(HEX_DIGEST) ~= nil
end

-- The current key plus the stored fingerprint when a matching snapshot
-- exists. A missing marker returns nil; any other anomaly (no snapshot file,
-- unknown schema, stale key, malformed content) is a miss the caller falls
-- back from to the slow validated build. Never raises.
---@param cacheFs table CacheFs-shaped
---@param overrideFs table read-shaped filesystem for data/scripts/overrides
---@return table|nil { key: string, fingerprint: string|nil }
function RegistrySnapshot.load(cacheFs, overrideFs)
  local key = RegistrySnapshot.key(cacheFs, overrideFs)
  if key == nil then
    return nil
  end
  local data = cacheFs:read(RegistrySnapshot.FILE)
  local snapshot
  if data ~= nil then
    local chunk = loadstring(data, RegistrySnapshot.FILE)
    if chunk then
      local ok, loaded = pcall(chunk)
      if ok then
        snapshot = loaded
      end
    end
  end
  local fingerprint
  if
    type(snapshot) == "table"
    and snapshot.schema == RegistrySnapshot.SCHEMA
    and snapshot.key == key
    and isHexDigest(snapshot.fingerprint)
  then
    fingerprint = snapshot.fingerprint
  end
  return { key = key, fingerprint = fingerprint }
end

-- Persist the snapshot only while the world still matches the key the
-- fingerprint was computed under: a mid-session override edit would make the
-- stored digest invalid, so the write is skipped and the next boot rebuilds
-- slowly. The snapshot is optional cache state, so a failed write only costs
-- one slow boot; it never fails the caller and never reports success after a
-- failed write.
---@param cacheFs table CacheFs-shaped
---@param overrideFs table read-shaped filesystem for data/scripts/overrides
---@param fingerprint string
---@param expectedKey string|nil key the fingerprint was computed under
---@return boolean
function RegistrySnapshot.save(cacheFs, overrideFs, fingerprint, expectedKey)
  assert(type(fingerprint) == "string" and fingerprint ~= "", "snapshot fingerprint required")
  local key = RegistrySnapshot.key(cacheFs, overrideFs)
  if key == nil or key ~= expectedKey then
    return false
  end
  local ok, result = pcall(cacheFs.writeLua, cacheFs, RegistrySnapshot.FILE, {
    schema = RegistrySnapshot.SCHEMA,
    key = key,
    fingerprint = fingerprint,
  })
  if not ok then
    return false
  end
  return result == true
end

return RegistrySnapshot
