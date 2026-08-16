-- Synthetic audio bundle and cache fixtures for the asset/cache contract
-- tests and the engine audio runtime tests. The bundle follows the
-- compiler-bundle shape (marker/index/sequences/banks/samples/
-- sampleMetadata/dependencies) with assets matching the frozen audio shapes:
-- zero-based sequence/bank ids, content-addressed samples, semantic
-- instruction IR with index branch targets, direct/key_split/drum_set
-- instruments, and sample/square/noise voices. readyCache writes a bundle
-- straight into a CacheFs (paths via AudioCache) without the production
-- writer, so libs/assets unit tests and libs/engine audio tests can build
-- ready caches without importing romdump. Test-only fixture.

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

-- Encodes signed int16 samples as little-endian PCM16LE bytes.
---@param samples integer[]
---@return string
function AudioFixture.pcm16le(samples)
  local bytes = {}
  for i = 1, #samples do
    local s = samples[i]
    if s < 0 then
      s = s + 65536
    end
    bytes[#bytes + 1] = string.char(s % 256, math.floor(s / 256) % 256)
  end
  return table.concat(bytes)
end

function AudioFixture.sampleVoice(key)
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
end

function AudioFixture.squareVoice()
  return {
    generator = { kind = "square", duty = 4 },
    originalKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
end

function AudioFixture.noiseVoice()
  return {
    generator = { kind = "noise" },
    originalKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
end

-- A valid sequence asset. `program` overrides the default program so engine
-- tests can author hand-written programs over the frozen
-- instruction shapes; `player` overrides the player block fields.
function AudioFixture.sequence(id, symbol, bankId, playerId, program, player)
  local sequence = {
    schema = AudioCache.SEQUENCE_SCHEMA,
    id = id,
    symbol = symbol,
    bankId = bankId,
    player = player or {
      id = playerId,
      initialVolume = 127,
      playerPriority = 64,
    },
    program = program or {
      entry = 1,
      instructions = {
        { op = "program", program = 4 },
        { op = "note", key = 60, velocity = 96, duration = 24 },
        { op = "wait", duration = 12 },
        { op = "jump", target = 2 },
      },
    },
  }
  return sequence
end

-- `instruments` overrides the default instrument map so engine tests can
-- author banks over the frozen instrument/voice shapes.
function AudioFixture.bank(id, symbol, sampleKeys, instruments)
  sampleKeys = sampleKeys or { AudioFixture.key(1), AudioFixture.key(2) }
  return {
    schema = AudioCache.BANK_SCHEMA,
    id = id,
    symbol = symbol,
    instruments = instruments or {
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

-- `opts` overrides frames/baseTimer/loop/loopEnabled so engine tests can pin
-- a wave's base timer, loop flag, and loop window; `file` and the source
-- `sampleRate` are deliberately absent from the derived shape (the payload
-- path derives from the content key, and playback comes from the DS sound
-- clock and the calculated timer). One-shot waves (loopEnabled false) must
-- carry the full-range window, mirroring the compiler's normalization.
-- baseTimer defaults to 8006, the DS PSG base timer (the DS sample clock
-- 16756991 Hz over 8006 is about 2093 Hz); it is the value the mixer suites
-- pin, and it makes octave ratios exact (key 72 -> ratio exactly 2.0).
function AudioFixture.sampleMetadata(key, opts)
  opts = opts or {}
  local frames = opts.frames or 8214
  local loop = opts.loop or { startFrame = 0, endFrame = frames }
  return {
    schema = AudioCache.SAMPLE_SCHEMA,
    key = key,
    frames = frames,
    baseTimer = opts.baseTimer or 8006,
    loopEnabled = opts.loopEnabled ~= false,
    loop = loop,
  }
end

-- A full E1-shaped audio bundle over a small synthetic archive: two
-- sequences on one bank, three instruments, two content-addressed samples
-- whose payloads are real PCM16LE bytes matching their metadata frames.
function AudioFixture.bundle()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  local pcmA = AudioFixture.pcm16le({ 1000, 2000, 3000, 4000 })
  local pcmB = AudioFixture.pcm16le({ 5000, 6000 })
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
        [12] = { id = 12, symbol = "BANK_TEST", file = AudioCache.bankPath(12) },
      },
      players = {
        [1] = { id = 1, maxSequences = 16, channelMask = 0xFFFF },
      },
      sequenceBySymbol = {
        ["SEQ_TEST_A"] = 0,
        ["SEQ_TEST_B"] = 37,
      },
      bankBySymbol = {
        ["BANK_TEST"] = 12,
      },
    },
    sequences = {
      [0] = AudioFixture.sequence(0, "SEQ_TEST_A", 12, 1),
      [37] = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1),
    },
    banks = {
      [12] = AudioFixture.bank(12, "BANK_TEST"),
    },
    samples = {
      [keyA] = pcmA,
      [keyB] = pcmB,
    },
    sampleMetadata = {
      [keyA] = AudioFixture.sampleMetadata(keyA, { frames = 4 }),
      [keyB] = AudioFixture.sampleMetadata(keyB, { frames = 2 }),
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
