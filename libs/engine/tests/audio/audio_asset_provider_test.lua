-- AudioAssetProvider contract: the runtime owner of the generated audio cache.
-- It loads the index eagerly at construction, resolves sequences/banks by
-- numeric id or per-class symbol map (sequenceBySymbol/bankBySymbol), and
-- loads sequence/bank/sample assets lazily and memoized with strict
-- validation. Samples arrive as metadata plus the provider-decoded PCM
-- array, decoded exactly once per key. The contract is authored against
-- hand-written project-owned synthetic assets; nothing
-- here touches a ROM. Loading policy: index eager, sequence/bank/
-- sample descriptors lazy + memoized, loaded assets stay cached for the
-- process lifetime.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.AudioCache")
local AudioFixture = require("tests.support.AudioFixture")
local FakeCache = require("tests.support.FakeCache")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

local function provider(bundle)
  local cache = AudioFixture.readyCache(bundle)
  return AudioAssetProvider.new(cache), cache
end

-- A backend proxy counting every read by version-relative path (the backend
-- sees version-prefixed full paths, but the assertions count with
-- AudioCache's relative paths), so lazy+memoized loading is observable: an
-- asset is read exactly once no matter how often it is asked for, and never
-- read until it is asked for.
local function countingBackend(backend)
  local reads = {}
  local proxy = setmetatable({}, {
    __index = function(self, key)
      if key == "read" then
        return function(_, path)
          local relative = path:gsub("^[^/]+/", "")
          reads[relative] = (reads[relative] or 0) + 1
          return backend:read(path)
        end
      end
      return backend[key]
    end,
  })
  proxy.reads = reads
  return proxy
end

function T.constructs_from_a_ready_cache_and_resolves_ids_and_symbols()
  local p = provider(AudioFixture.bundle())
  local sequence = p:sequence(0)
  Assert.equal(sequence.schema, AudioCache.SEQUENCE_SCHEMA)
  Assert.equal(sequence.id, 0)
  Assert.equal(p:sequence("SEQ_TEST_A"), sequence, "symbol resolution shares the memoized asset")
  Assert.equal(p:sequence(37).symbol, "SEQ_TEST_B")
  Assert.equal(p:sequence("SEQ_TEST_B").id, 37)
  local bank = p:bank(12)
  Assert.equal(bank.schema, AudioCache.BANK_SCHEMA)
  Assert.equal(bank.id, 12)
  Assert.equal(p:bank("BANK_TEST"), bank, "symbol resolution shares the memoized asset")
  Assert.equal(p:player(1).channelMask, 0xFFFF)
  Assert.equal(p:player(1).maxSequences, 16)
end

-- Symbols resolve per asset class: the same symbol may name a sequence and
-- a bank, and each lookup walks its own map, so a cross-class collision is
-- never ambiguous.
function T.symbol_collisions_across_classes_resolve_per_class()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[37].symbol = "SHARED"
  bundle.index.banks[12].symbol = "SHARED"
  bundle.index.sequenceBySymbol.SHARED = 37
  bundle.index.bankBySymbol.SHARED = 12
  bundle.sequences[37].symbol = "SHARED"
  bundle.banks[12].symbol = "SHARED"
  local p = provider(bundle)
  Assert.equal(p:sequence("SHARED").id, 37)
  Assert.equal(p:bank("SHARED").id, 12)
end

function T.unknown_references_raise_structured_errors()
  local p = provider(AudioFixture.bundle())
  throwsCode("AUDIO_PROVIDER_SEQUENCE_UNKNOWN", function()
    p:sequence(99)
  end)
  throwsCode("AUDIO_PROVIDER_SEQUENCE_UNKNOWN", function()
    p:sequence("SEQ_MISSING")
  end)
  throwsCode("AUDIO_PROVIDER_BANK_UNKNOWN", function()
    p:bank(99)
  end)
  throwsCode("AUDIO_PROVIDER_PLAYER_UNKNOWN", function()
    p:player(99)
  end)
end

function T.samples_load_by_content_key_with_metadata_and_decoded_pcm()
  local p = provider(AudioFixture.bundle())
  local key = AudioFixture.key(1)
  local sample = p:loadSample(key)
  Assert.equal(sample.metadata.key, key)
  Assert.equal(sample.metadata.schema, AudioCache.SAMPLE_SCHEMA)
  Assert.deepEqual(sample.pcm, { 1000, 2000, 3000, 4000 }, "the provider hands over the decoded PCM array")
end

-- The payload size contract is enforced at the load boundary: metadata whose
-- payload is not exactly frames*2 bytes of PCM16LE is malformed, never
-- silence.
function T.malformed_sample_payload_byte_count_fails_load()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  bundle.samples[key] = bundle.samples[key] .. "\0"
  local p = provider(bundle)
  throwsCode("AUDIO_SAMPLE_INVALID", function()
    p:loadSample(key)
  end)
end

function T.unknown_sample_keys_and_missing_payloads_fail()
  local bundle = AudioFixture.bundle()
  local p, cache = provider(bundle)
  throwsCode("AUDIO_PROVIDER_SAMPLE_UNKNOWN", function()
    p:loadSample(AudioFixture.key(99))
  end)
  cache:remove(AudioCache.samplePath(AudioFixture.key(1)))
  throwsCode("AUDIO_PROVIDER_SAMPLE_UNKNOWN", function()
    p:loadSample(AudioFixture.key(1))
  end)
end

function T.loading_is_lazy_and_memoized()
  local backend = countingBackend(FakeCache.new())
  local counted = AudioFixture.readyCache(AudioFixture.bundle(), backend)
  local baseline = {}
  for path, reads in pairs(backend.reads) do
    baseline[path] = reads
  end
  local p = AudioAssetProvider.new(counted)
  local reads = backend.reads
  local function count(path)
    return (reads[path] or 0) - (baseline[path] or 0)
  end
  Assert.equal(count(AudioCache.indexPath()), 1, "the index loads once, eagerly")
  local sequence = p:sequence(0)
  Assert.equal(count(AudioCache.sequencePath(0)), 1, "the sequence loads on first access")
  Assert.equal(p:sequence(0), sequence, "memoized: same table, no second read")
  Assert.equal(count(AudioCache.sequencePath(0)), 1)
  local bank = p:bank(12)
  Assert.equal(count(AudioCache.bankPath(12)), 1, "the bank loads on first access")
  Assert.equal(p:bank(12), bank)
  Assert.equal(count(AudioCache.bankPath(12)), 1)
  local key = AudioFixture.key(1)
  local first = p:loadSample(key)
  local second = p:loadSample(key)
  Assert.equal(type(first.pcm), "table", "the provider decodes the payload once")
  Assert.isTrue(second.pcm == first.pcm, "the decoded array is shared; loading twice decodes once")
  Assert.equal(count(AudioCache.sampleMetadataPath(key)), 1, "sample metadata is read once")
  Assert.equal(count(AudioCache.samplePath(key)), 1, "the PCM payload is read once")
  Assert.equal(count(AudioCache.sequencePath(37)), 0, "unrequested assets are never read")
  Assert.equal(count(AudioCache.bankPath(12)), 1)
end

function T.missing_or_malformed_index_fails_construction()
  throwsCode("AUDIO_PROVIDER_INDEX_UNAVAILABLE", function()
    local cache = AudioFixture.readyCache(AudioFixture.bundle())
    cache:remove(AudioCache.indexPath())
    AudioAssetProvider.new(cache)
  end)
  throwsCode("AUDIO_PROVIDER_INDEX_UNAVAILABLE", function()
    local bundle = AudioFixture.bundle()
    bundle.index.schema = "g4-audio-index-wrong"
    AudioAssetProvider.new(AudioFixture.readyCache(bundle))
  end)
end

function T.malformed_sequence_asset_fails_on_access()
  local bundle = AudioFixture.bundle()
  bundle.sequences[0].schema = "not-a-sequence"
  local p = provider(bundle)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    p:sequence(0)
  end)
end

function T.malformed_bank_asset_fails_on_access()
  local bundle = AudioFixture.bundle()
  bundle.banks[12].instruments = {}
  local p = provider(bundle)
  throwsCode("AUDIO_BANK_INVALID", function()
    p:bank(12)
  end)
end

return { tests = T }
