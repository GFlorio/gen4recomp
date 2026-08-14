-- Synthetic audio bundle and cache fixtures for the asset/cache contract
-- tests. The bundle follows the compiler-bundle shape
-- (marker/index/sequences/banks/samples/sampleMetadata/dependencies) with
-- assets matching the frozen audio shapes: zero-based sequence/bank ids,
-- content-addressed samples, semantic instruction IR with index branch
-- targets, direct/key_split/drum_set instruments, and sample/square/noise
-- voices. readyCache writes a bundle straight into a CacheFs (paths via
-- AudioCache) without the production writer, so libs/assets unit tests can
-- build ready caches without importing romdump. Test-only fixture.

local AudioCache = require("libs.assets.src.AudioCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local AudioFixture = {}

-- A deterministic sha1-shaped content key (40 lowercase hex chars). Content
-- addressing keys are also file-path components, so only the sha1 shape is
-- ever valid.
function AudioFixture.key(n)
  return string.format("%040x", n)
end

function AudioFixture.sampleVoice(key)
  return {
    generator = { kind = "sample", sample = key },
    rootKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
end

function AudioFixture.squareVoice()
  return {
    generator = { kind = "square", duty = 0.5 },
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
end

function AudioFixture.noiseVoice()
  return {
    generator = { kind = "noise" },
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
end

function AudioFixture.sequence(id, symbol, bankId, playerId)
  return {
    schema = AudioCache.SEQUENCE_SCHEMA,
    id = id,
    symbol = symbol,
    bankId = bankId,
    player = {
      id = playerId,
      initialVolume = 127,
      channelPriority = 64,
      playerPriority = 64,
    },
    program = {
      entry = 1,
      instructions = {
        { op = "program", program = 4 },
        { op = "note", key = 60, velocity = 96, duration = 24 },
        { op = "rest", duration = 12 },
        { op = "jump", target = 2 },
      },
    },
  }
end

function AudioFixture.bank(id, symbol, waveArchives, sampleKeys)
  sampleKeys = sampleKeys or { AudioFixture.key(1), AudioFixture.key(2) }
  return {
    schema = AudioCache.BANK_SCHEMA,
    id = id,
    symbol = symbol,
    waveArchives = waveArchives,
    instruments = {
      [0] = { kind = "direct", voice = AudioFixture.sampleVoice(sampleKeys[1]) },
      [1] = {
        kind = "key_split",
        ranges = {
          { lowKey = 0, highKey = 59, voice = AudioFixture.sampleVoice(sampleKeys[1]) },
          { lowKey = 60, highKey = 127, voice = AudioFixture.sampleVoice(sampleKeys[2]) },
        },
      },
      [2] = {
        kind = "drum_set",
        lowKey = 35,
        highKey = 36,
        voices = { AudioFixture.squareVoice(), AudioFixture.noiseVoice() },
      },
    },
  }
end

function AudioFixture.sampleMetadata(key)
  return {
    schema = AudioCache.SAMPLE_SCHEMA,
    key = key,
    file = AudioCache.samplePath(key),
    frames = 8214,
    sampleRate = 32768,
    loop = { startFrame = 0, endFrame = 8214 },
  }
end

-- A full E1-shaped audio bundle over a small synthetic archive: two
-- sequences on one bank, three instruments, two content-addressed samples.
function AudioFixture.bundle()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  return {
    marker = AudioCache.marker("rom-sha", "dep-sha"),
    index = {
      schema = AudioCache.INDEX_SCHEMA,
      version = "heartgold",
      sequences = {
        [0] = { id = 0, symbol = "SEQ_TEST_A", file = AudioCache.sequencePath(0), bankId = 12, playerId = 1 },
        [37] = { id = 37, symbol = "SEQ_TEST_B", file = AudioCache.sequencePath(37), bankId = 12, playerId = 1 },
      },
      banks = {
        [12] = { id = 12, symbol = "BANK_TEST", file = AudioCache.bankPath(12), waveArchives = { [0] = 31 } },
      },
      players = {
        [1] = { id = 1, maxSequences = 16, channelMask = 0xFFFF, heapSize = 0x2000 },
      },
      bySymbol = {
        ["SEQ_TEST_A"] = 0,
        ["SEQ_TEST_B"] = 37,
        ["BANK_TEST"] = 12,
      },
    },
    sequences = {
      [0] = AudioFixture.sequence(0, "SEQ_TEST_A", 12, 1),
      [37] = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1),
    },
    banks = {
      [12] = AudioFixture.bank(12, "BANK_TEST", { [0] = 31 }),
    },
    samples = {
      [keyA] = "pcm-a",
      [keyB] = "pcm-b",
    },
    sampleMetadata = {
      [keyA] = AudioFixture.sampleMetadata(keyA),
      [keyB] = AudioFixture.sampleMetadata(keyB),
    },
    dependencies = {
      cacheFormat = AudioCache.FORMAT,
      versionRomSha1 = "rom-sha",
      soundArchive = { path = "data/sound/gs_sound_data.sdat", fileId = 13, sha1 = "archive-sha" },
    },
  }
end

-- Writes a bundle into a fresh FakeCache-backed CacheFs at AudioCache's
-- canonical paths, mirroring the writer's layout without using the writer.
function AudioFixture.readyCache(bundle, backend)
  bundle = bundle or AudioFixture.bundle()
  local cache = CacheFs.forVersion("heartgold", backend or FakeCache.new())
  cache:writeLua(AudioCache.provenancePath(), {
    schema = AudioCache.PROVENANCE_SCHEMA,
    dependencies = bundle.dependencies,
  })
  cache:writeLua(AudioCache.indexPath(), bundle.index)
  for id, sequence in pairs(bundle.sequences) do
    cache:writeLua(AudioCache.sequencePath(id), sequence)
  end
  for id, bank in pairs(bundle.banks) do
    cache:writeLua(AudioCache.bankPath(id), bank)
  end
  for key, bytes in pairs(bundle.samples) do
    cache:write(AudioCache.samplePath(key), bytes)
    cache:writeLua(AudioCache.sampleMetadataPath(key), bundle.sampleMetadata[key])
  end
  cache:write(AudioCache.markerPath(), bundle.marker)
  return cache
end

return AudioFixture
