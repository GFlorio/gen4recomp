-- Runtime owner of the derived audio cache. It loads the audio index
-- eagerly at construction, resolves sequences and banks by numeric id
-- or symbolic name through the index's per-class symbol maps
-- (sequenceBySymbol/bankBySymbol), and loads sequence, bank, and sample
-- assets lazily with per-asset memoization. The cache is a TRUSTED runtime
-- input: generated audio files are deep-validated exactly once by the
-- authoritative cross-file readiness walk (AudioCacheValidator, the same
-- walk the cache writer's staged readback runs), so load-time re-validation
-- is deliberately absent -- there is no runtime mod-injection path that
-- bypasses the builder. Missing or unreadable artifacts are still structured
-- failures, never silence. Samples arrive as metadata plus the
-- provider-decoded PCM array, decoded exactly once per key and shared across
-- consumers. Loading policy: index eager; sequence/bank/sample descriptors
-- lazy + memoized, loaded assets stay cached for the process lifetime. It is
-- the only module that reads the audio cache: it never parses SDAT/SSEQ and
-- never plays notes. The completion marker is not consulted (there is no
-- expected marker value at runtime; readiness is the cache builder's
-- business).

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.hgss.src.audio.AudioErrors")
local AssetErrors = require("libs.assets.src.AudioErrors")
local AudioCache = require("libs.assets.src.AudioCache")

---@class AudioAssetProvider
---@field private _cacheFs CacheFs
---@field private _index table
---@field private _sequences table<integer, table>
---@field private _banks table<integer, table>
---@field private _samples table<string, table>
---@field new fun(cacheFs: CacheFs): AudioAssetProvider
---@field sequence fun(self: AudioAssetProvider, idOrSymbol: integer|string): table
---@field bank fun(self: AudioAssetProvider, idOrSymbol: integer|string): table
---@field player fun(self: AudioAssetProvider, id: integer): table
---@field loadSample fun(self: AudioAssetProvider, key: string): { metadata: table, pcm: integer[] }

local AudioAssetProvider = {}
AudioAssetProvider.__index = AudioAssetProvider

local function unavailable(path)
  Errors.raise(AudioErrors.AUDIO_PROVIDER_INDEX_UNAVAILABLE, "no usable audio cache index at " .. path, { path = path })
end

---@return AudioAssetProvider
---@param cacheFs CacheFs
function AudioAssetProvider.new(cacheFs)
  assert(cacheFs, "AudioAssetProvider requires a CacheFs")
  local index = cacheFs:loadLua(AudioCache.indexPath())
  if type(index) ~= "table" or index.schema ~= AudioCache.INDEX_SCHEMA then
    unavailable(AudioCache.indexPath())
  end
  local provider = setmetatable({
    _cacheFs = cacheFs,
    _index = index,
    _sequences = {},
    _banks = {},
    _samples = {},
  }, AudioAssetProvider)
  return provider --[[@as AudioAssetProvider]]
end

-- Resolves a numeric id or a per-class symbol-map name to a numeric id in
-- `section`, or nil when the reference is unknown.
---@param section table
---@param symbolMap table?
---@param idOrSymbol integer|string
---@return integer?
local function resolveId(section, symbolMap, idOrSymbol)
  if type(idOrSymbol) == "number" then
    if section[idOrSymbol] ~= nil then
      return idOrSymbol
    end
    return nil
  end
  if type(idOrSymbol) == "string" and symbolMap and symbolMap[idOrSymbol] ~= nil then
    local id = symbolMap[idOrSymbol]
    if section[id] ~= nil then
      return id
    end
  end
  return nil
end

-- Loads the asset file at `path` once, memoized by id. A missing or
-- unreadable file is a structured failure; the file's content itself is
-- trusted (see the module header: readiness validates the whole cache).
---@param memo table<integer, table>
---@param cacheFs CacheFs
---@param id integer
---@param path string
---@param invalidCode string
---@return table
local function loadAsset(memo, cacheFs, id, path, invalidCode)
  local asset = memo[id]
  if asset ~= nil then
    return asset
  end
  local value = cacheFs:loadLua(path)
  if type(value) ~= "table" then
    Errors.raise(invalidCode, "missing or unreadable audio asset at " .. path, { path = path, id = id })
  end
  value = value --[[@as table]]
  memo[id] = value
  return value
end

function AudioAssetProvider:sequence(idOrSymbol)
  local id = resolveId(self._index.sequences, self._index.sequenceBySymbol, idOrSymbol)
  if id == nil then
    Errors.raise(
      AudioErrors.AUDIO_PROVIDER_SEQUENCE_UNKNOWN,
      "no indexed audio sequence for reference " .. tostring(idOrSymbol),
      {
        reference = idOrSymbol,
      }
    )
  end
  return loadAsset(
    self._sequences,
    self._cacheFs,
    id --[[@as integer]],
    AudioCache.sequencePath(id),
    AssetErrors.AUDIO_SEQUENCE_INVALID
  )
end

function AudioAssetProvider:bank(idOrSymbol)
  local id = resolveId(self._index.banks, self._index.bankBySymbol, idOrSymbol)
  if id == nil then
    Errors.raise(
      AudioErrors.AUDIO_PROVIDER_BANK_UNKNOWN,
      "no indexed audio bank for reference " .. tostring(idOrSymbol),
      {
        reference = idOrSymbol,
      }
    )
  end
  return loadAsset(
    self._banks,
    self._cacheFs,
    id --[[@as integer]],
    AudioCache.bankPath(id),
    AssetErrors.AUDIO_BANK_INVALID
  )
end

function AudioAssetProvider:player(id)
  local player = self._index.players and self._index.players[id]
  if type(player) ~= "table" then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_PLAYER_UNKNOWN, "no indexed audio player " .. tostring(id), { id = id })
  end
  return player
end

-- Decodes the PCM16LE payload into the shared 1-based int16 sample array.
---@param bytes string
---@return integer[]
local function decodePcm(bytes)
  local samples = {}
  for index = 0, #bytes / 2 - 1 do
    local low = bytes:byte(index * 2 + 1)
    local high = bytes:byte(index * 2 + 2)
    local value = low + high * 256
    if value >= 32768 then
      value = value - 65536
    end
    samples[index + 1] = value
  end
  return samples
end

-- Loads a sample's metadata and decoded PCM array by content key, memoized.
-- Both files must exist; a missing or unreadable file is
-- AUDIO_PROVIDER_SAMPLE_UNKNOWN. The decoded array is created once per key
-- and shared (consumers must not mutate it).
function AudioAssetProvider:loadSample(key)
  local sample = self._samples[key]
  if sample ~= nil then
    return sample
  end
  local metadata = self._cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
  if type(metadata) ~= "table" then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "no audio sample metadata for key " .. key, { key = key })
  end
  local bytes = self._cacheFs:read(AudioCache.samplePath(key))
  if bytes == nil then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "no audio sample payload for key " .. key, { key = key })
  end
  sample = {
    metadata = metadata,
    pcm = decodePcm(bytes --[[@as string]]),
  }
  self._samples[key] = sample
  return sample
end

return AudioAssetProvider
