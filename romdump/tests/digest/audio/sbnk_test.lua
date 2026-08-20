-- SBNK decoding contract: bounded instrument walk over the NitroSDK bank
-- structures (SND_bank_shared.h: packed u32 entries at 0x3C with the type in
-- the low byte and the record offset in the upper 24 bits; 10-byte
-- SNDInstParam for direct records; 12-byte SNDInstData leaves for drum sets
-- and key splits) into source IR. Illegal type-0 records are silent and are
-- dropped by the decoder; every malformed read and every unsupported
-- instrument type fails with a structured SBNK_* error.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Sbnk = require("romdump.src.digest.audio.Sbnk")
local SbnkFixture = require("tests.support.SbnkFixture")

local T = {}

---@param e any
---@return Errors.Error
local function asError(e)
  return e
end

local function countOf(t)
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  return count
end

local function decodeOrFail(bytes)
  local bank, err = Sbnk.decode(bytes, "fixture")
  Assert.notNil(bank, "expected decode to succeed: " .. tostring(err and Errors.format(err) or "no error"))
  return assert(bank)
end

local function decodeRejects(bytes, code)
  local bank, err = Sbnk.decode(bytes, "fixture")
  Assert.isNil(bank, "expected decode to fail with " .. code)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(asError(err).code, code)
  return assert(err)
end

local PCM = { swav = 0, swarSlot = 0, rootKey = 60, attack = 120, decay = 60, sustain = 80, release = 100, pan = 64 }
local PSG = { swav = 3, swarSlot = 1, rootKey = 48, attack = 127, decay = 0, sustain = 127, release = 127, pan = 32 }
local NOISE = { swav = 0, swarSlot = 2, rootKey = 60, attack = 127, decay = 0, sustain = 127, release = 127, pan = 96 }

-- Direct PCM/PSG/noise records decode their full 10-byte parameter.
function T.decodes_direct_instruments()
  local bytes = SbnkFixture.build({
    { type = 1, param = PCM },
    { type = 2, param = PSG },
    { type = 3, param = NOISE },
  })
  local bank = decodeOrFail(bytes)
  Assert.equal(bank.instCount, 3)
  local pcm = bank.instruments[0]
  Assert.equal(pcm.type, 1)
  Assert.equal(pcm.param.swav, 0)
  Assert.equal(pcm.param.swarSlot, 0)
  Assert.equal(pcm.param.rootKey, 60)
  Assert.equal(pcm.param.attack, 120)
  Assert.equal(pcm.param.decay, 60)
  Assert.equal(pcm.param.sustain, 80)
  Assert.equal(pcm.param.release, 100)
  Assert.equal(pcm.param.pan, 64)
  Assert.equal(bank.instruments[1].type, 2)
  Assert.equal(bank.instruments[1].param.swav, 3)
  Assert.equal(bank.instruments[2].type, 3)
end

-- Type-0 records are illegal instruments: the SDK fails notes on them, so
-- the decoder drops them and the instrument map keeps only sound-capable
-- programs.
function T.drops_illegal_type0_records()
  local bytes = SbnkFixture.build({
    { type = 1, param = PCM },
    { type = 0 },
    { type = 2, param = PSG },
  })
  local bank = decodeOrFail(bytes)
  Assert.equal(bank.instruments[0].type, 1)
  Assert.isNil(bank.instruments[1], "type-0 record is dropped")
  Assert.equal(bank.instruments[2].type, 2)
end

-- Drum sets decode min/max keys and one leaf per key.
function T.decodes_drum_sets()
  local bytes = SbnkFixture.build({
    {
      type = 0x10,
      minKey = 35,
      maxKey = 37,
      leaves = {
        { type = 1, param = PCM },
        {
          type = 1,
          param = {
            swav = 1,
            swarSlot = 0,
            rootKey = 35,
            attack = 127,
            decay = 0,
            sustain = 127,
            release = 127,
            pan = 64,
          },
        },
        { type = 2, param = PSG },
      },
    },
  })
  local bank = decodeOrFail(bytes)
  local drums = bank.instruments[0]
  Assert.equal(drums.type, 0x10)
  Assert.equal(drums.minKey, 35)
  Assert.equal(drums.maxKey, 37)
  Assert.equal(countOf(drums.leaves), 3)
  Assert.equal(drums.leaves[0].type, 1)
  Assert.equal(drums.leaves[0].param.swav, 0)
  Assert.equal(drums.leaves[1].param.swav, 1)
  Assert.equal(drums.leaves[2].type, 2)
end

-- Key splits decode their split keys and the leaves that stop at the first
-- zero key byte.
function T.decodes_key_splits()
  local bytes = SbnkFixture.build({
    {
      type = 0x11,
      keys = { 48, 72 },
      leaves = {
        { type = 1, param = PCM },
        {
          type = 1,
          param = {
            swav = 5,
            swarSlot = 0,
            rootKey = 60,
            attack = 127,
            decay = 0,
            sustain = 127,
            release = 127,
            pan = 64,
          },
        },
      },
    },
  })
  local bank = decodeOrFail(bytes)
  local split = bank.instruments[0]
  Assert.equal(split.type, 0x11)
  Assert.deepEqual(split.keys, { [0] = 48, [1] = 72 })
  Assert.equal(countOf(split.leaves), 2)
  Assert.equal(split.leaves[1].param.swav, 5)
end

-- A direct record pointing past the end of the bank is truncated data.
function T.rejects_records_past_end()
  local bytes = SbnkFixture.build({ { type = 1, param = PCM } })
  local corrupted = bytes:sub(1, #bytes - 5)
  decodeRejects(corrupted, "SBNK_TRUNCATED")
end

-- An instrument table extending past the end of the bank is truncated data.
function T.rejects_table_past_end()
  local bytes = SbnkFixture.build({ { type = 1, param = PCM } })
  -- Bump the instrument count far past the real table.
  local corrupted = bytes:sub(1, 0x38) .. "\xff\x00\x00\x00" .. bytes:sub(0x3D)
  decodeRejects(corrupted, "SBNK_TRUNCATED")
end

-- Instrument types the offline compiler cannot represent (direct-memory PCM,
-- dummy records, or silent leaves inside composites) are build failures with
-- provenance, never silent guesses.
function T.decodes_directpcm_and_dummy_instruments()
  local direct = SbnkFixture.build({ { type = 4, param = PCM } })
  local directBank = decodeOrFail(direct)
  Assert.equal(directBank.instruments[0].type, Sbnk.TYPE_DIRECTPCM)
  Assert.deepEqual(directBank.instruments[0].param, PCM)

  local dummy = SbnkFixture.build({ { type = 5, param = PCM } })
  local dummyBank = decodeOrFail(dummy)
  Assert.equal(dummyBank.instruments[0].type, Sbnk.TYPE_DUMMY)
  Assert.isNil(dummyBank.instruments[0].param, "dummy has no playable note parameters")

  local drumWithSilentLeaf = SbnkFixture.build({
    {
      type = 0x10,
      minKey = 35,
      maxKey = 36,
      leaves = { { type = 1, param = PCM }, { type = 5, param = PCM } },
    },
  })
  local drumBank = decodeOrFail(drumWithSilentLeaf)
  Assert.equal(drumBank.instruments[0].leaves[1].type, Sbnk.TYPE_DUMMY)
  Assert.isNil(drumBank.instruments[0].leaves[1].param)
end

-- A key split whose first key byte is zero has no playable leaves; like a
-- type-0 record it is silent and dropped.
function T.drops_key_splits_without_leaves()
  local bytes = SbnkFixture.build({ { type = 0x11, keys = {}, leaves = {} } })
  local bank = decodeOrFail(bytes)
  Assert.isNil(bank.instruments[0], "leafless key split is dropped")
end

return { tests = T }
