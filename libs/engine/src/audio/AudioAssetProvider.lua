-- Runtime owner of the derived audio cache. It loads the audio index
-- eagerly at construction, resolves sequences and banks by numeric id
-- or symbolic name through the index's bySymbol map, and loads sequence,
-- bank, and sample assets lazily with per-asset memoization and strict
-- validation (the asset validators raise AUDIO_*_INVALID on malformed
-- files). Loading policy: index eager; sequence/bank/sample lazy +
-- memoized; no eviction in V1. It is the only module that reads the audio
-- cache: it never parses SDAT/SSEQ and never plays notes. Missing or
-- malformed artifacts are structured failures, never silence, and the
-- completion marker is not consulted (there is no expected marker value at
-- runtime; readiness is the cache builder's business).

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local AudioCache = require("libs.assets.src.AudioCache")
local AudioSequence = require("libs.assets.src.AudioSequence")
local AudioBank = require("libs.assets.src.AudioBank")
local AudioSample = require("libs.assets.src.AudioSample")

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
---@field loadSample fun(self: AudioAssetProvider, key: string): { metadata: table, pcm: string }

local AudioAssetProvider = {}
AudioAssetProvider.__index = AudioAssetProvider

local function unavailable(path)
  Errors.raise(FieldErrors.AUDIO_PROVIDER_INDEX_UNAVAILABLE, "no usable audio cache index at " .. path, { path = path })
end

function AudioAssetProvider.new(cacheFs)
  assert(cacheFs, "AudioAssetProvider requires a CacheFs")
  local index = cacheFs:loadLua(AudioCache.indexPath())
  if type(index) ~= "table" or index.schema ~= AudioCache.INDEX_SCHEMA then
    unavailable(AudioCache.indexPath())
  end
  return setmetatable({
    _cacheFs = cacheFs,
    _index = index,
    _sequences = {},
    _banks = {},
    _samples = {},
  }, AudioAssetProvider)
end

-- Resolves a numeric id or bySymbol name to a numeric id in `section`,
-- or nil when the reference is unknown.
---@param section table
---@param bySymbol table?
---@param idOrSymbol integer|string
---@return integer?
local function resolveId(section, bySymbol, idOrSymbol)
  if type(idOrSymbol) == "number" then
    if section[idOrSymbol] ~= nil then
      return idOrSymbol
    end
    return nil
  end
  if type(idOrSymbol) == "string" and bySymbol and bySymbol[idOrSymbol] ~= nil then
    local id = bySymbol[idOrSymbol]
    if section[id] ~= nil then
      return id
    end
  end
  return nil
end

-- Loads and validates the asset file at `path` once, memoized by id.
---@param memo table<integer, table>
---@param cacheFs CacheFs
---@param id integer
---@param path string
---@param validate fun(asset: table): boolean
---@param invalidCode string
---@return table
local function loadAsset(memo, cacheFs, id, path, validate, invalidCode)
  local asset = memo[id]
  if asset ~= nil then
    return asset
  end
  local value = cacheFs:loadLua(path)
  if type(value) ~= "table" then
    Errors.raise(invalidCode, "missing or unreadable audio asset at " .. path, { path = path, id = id })
  end
  value = value --[[@as table]]
  validate(value)
  memo[id] = value
  return value
end

function AudioAssetProvider:sequence(idOrSymbol)
  local id = resolveId(self._index.sequences, self._index.bySymbol, idOrSymbol)
  if id == nil then
    Errors.raise(
      FieldErrors.AUDIO_PROVIDER_SEQUENCE_UNKNOWN,
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
    AudioSequence.validate,
    "AUDIO_SEQUENCE_INVALID"
  )
end

function AudioAssetProvider:bank(idOrSymbol)
  local id = resolveId(self._index.banks, self._index.bySymbol, idOrSymbol)
  if id == nil then
    Errors.raise(
      FieldErrors.AUDIO_PROVIDER_BANK_UNKNOWN,
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
    AudioBank.validate,
    "AUDIO_BANK_INVALID"
  )
end

function AudioAssetProvider:player(id)
  local player = self._index.players and self._index.players[id]
  if type(player) ~= "table" then
    Errors.raise(FieldErrors.AUDIO_PROVIDER_PLAYER_UNKNOWN, "no indexed audio player " .. tostring(id), { id = id })
  end
  return player
end

-- Loads a sample's metadata and PCM payload by content key, memoized. Both
-- must exist; a missing or unreadable file is AUDIO_PROVIDER_SAMPLE_UNKNOWN,
-- a malformed metadata record or payload byte count is the sample validator's
-- code.
function AudioAssetProvider:loadSample(key)
  local sample = self._samples[key]
  if sample ~= nil then
    return sample
  end
  local metadata = self._cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
  if type(metadata) ~= "table" then
    Errors.raise(FieldErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "no audio sample metadata for key " .. key, { key = key })
  end
  local pcm = self._cacheFs:read(AudioCache.samplePath(key))
  if pcm == nil then
    Errors.raise(FieldErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "no audio sample payload for key " .. key, { key = key })
  end
  AudioSample.validate(metadata, pcm)
  sample = { metadata = metadata, pcm = pcm }
  self._samples[key] = sample
  return sample
end

return AudioAssetProvider
