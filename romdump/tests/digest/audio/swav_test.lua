-- SWAR/SWAV decoding contract: member slicing with bounds validation, and
-- offline PCM conversion (PCM8/PCM16/ADPCM) into signed PCM16LE with
-- engine-meaningful frame and loop-window units. The size relation
-- memberSize == 12 + 4*(pnt+len) and the loop conversions follow the DS
-- channel registers as GBATEK documents them and melonDS implements them
-- (SOUNDxPNT/SOUNDxLEN in 4-byte words; ADPCM starts with a 4-byte
-- predictor/index header and decodes low nibble first). Loop windows are
-- {startFrame, endFrame}: [4*pnt, 4*(pnt+len)) for PCM8, [2*pnt,
-- 2*(pnt+len)) for PCM16, [8*(pnt-1), 8*(pnt+len-1)) for ADPCM; waves whose
-- loop flag is off (or whose loop point is the header) get the full-range
-- window {0, frames}.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Swar = require("romdump.src.digest.audio.Swar")
local Swav = require("romdump.src.digest.audio.Swav")
local SwarFixture = require("tests.support.SwarFixture")

local T = {}

---@param e any
---@return Errors.Error
local function asError(e)
  return e
end

local function decodeOrFail(bytes)
  local wave, err = Swav.decode(bytes, "fixture")
  Assert.notNil(wave, "expected decode to succeed: " .. tostring(err and Errors.format(err) or "no error"))
  return assert(wave)
end

local function decodeRejects(bytes, code)
  local wave, err = Swav.decode(bytes, "fixture")
  Assert.isNil(wave, "expected decode to fail with " .. code)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(asError(err).code, code)
  return assert(err)
end

local function pcm16Samples(payload)
  local samples = {}
  for i = 1, #payload, 2 do
    local b1, b2 = string.byte(payload, i, i + 1)
    local value = b1 + b2 * 256
    if value >= 0x8000 then
      value = value - 0x10000
    end
    samples[#samples + 1] = value
  end
  return samples
end

-- The SWAR container exposes zero-based members and slices them exactly.
function T.swar_slices_members()
  local memberA = SwarFixture.pcm8({ 1, 2, 3, 4 })
  local memberB = SwarFixture.pcm16({ -1, -2, -3, -4 })
  local bytes = SwarFixture.build({ memberA, memberB })
  local swar, err = Swar.decode(bytes, "fixture")
  Assert.notNil(swar, tostring(err))
  swar = assert(swar)
  Assert.equal(swar.waveCount, 2)
  Assert.equal(swar:readMember(0), memberA)
  Assert.equal(swar:readMember(1), memberB)
  local missing, missingErr = swar:readMember(2)
  Assert.isNil(missing)
  Assert.equal(missingErr.code, "SWAR_MEMBER_OUT_OF_RANGE")
end

-- A member table extending past the end of the file is truncated data.
function T.swar_rejects_table_past_end()
  local bytes = SwarFixture.build({ SwarFixture.pcm8({ 1, 2, 3, 4 }) })
  local corrupted = bytes:sub(1, 0x38) .. "\xff\x00\x00\x00" .. bytes:sub(0x3D)
  local swar, err = Swar.decode(corrupted, "fixture")
  Assert.isNil(swar)
  Assert.isTrue(Errors.is(err))
  Assert.equal(asError(err).code, "SWAR_TRUNCATED")
end

-- PCM8 converts signed bytes to their PCM16 equivalents (byte << 8).
function T.swav_decodes_pcm8()
  local bytes = SwarFixture.pcm8({ -128, -1, 0, 1, 127, -128, 1, 2 }, { sampleRate = 16000 })
  local wave = decodeOrFail(bytes)
  Assert.equal(wave.format, 0)
  Assert.equal(wave.sampleRate, 16000)
  Assert.equal(wave.frames, 8)
  Assert.deepEqual(wave.loop, { startFrame = 0, endFrame = 8 })
  Assert.deepEqual(pcm16Samples(wave.pcm16le), { -32768, -256, 0, 256, 32512, -32768, 256, 512 })
end

-- PCM16 converts little-endian signed pairs verbatim.
function T.swav_decodes_pcm16()
  local bytes = SwarFixture.pcm16({ -32768, -1, 0, 1, 32767, -1000 }, { sampleRate = 22050 })
  local wave = decodeOrFail(bytes)
  Assert.equal(wave.format, 1)
  Assert.equal(wave.sampleRate, 22050)
  Assert.equal(wave.frames, 6)
  Assert.deepEqual(wave.loop, { startFrame = 0, endFrame = 6 })
  Assert.deepEqual(pcm16Samples(wave.pcm16le), { -32768, -1, 0, 1, 32767, -1000 })
end

-- ADPCM decodes exactly per the GBATEK/melonDS algorithm: a 4-byte header
-- (predictor, index, pad), low nibble first, diff = step/8 plus step/4 for
-- bit 0, step/2 for bit 1, and step for bit 2, clamping to +-0x7FFF.
function T.swav_decodes_adpcm_exact_nibbles()
  -- predictor 1000, index 4 (step 11). Nibbles (low first): 0, 4, 9, 0, 0,
  -- 0, 0, 0 decode as: +1 -> 1001 (index 3, step 10); +11 (mag 4, step 10:
  -- 10/8 + 10) -> 1012 (index 5, step 12); -4 (mag 1, step 12: 12/8 + 12/4)
  -- -> 1008 (index 4, step 11); then +1, +1, +1, +1, +0 -> 1009, 1010,
  -- 1011, 1012, 1012.
  local nibbles = string.char(0x40, 0x09, 0x00, 0x00)
  local bytes = SwarFixture.adpcmRaw(1000, 4, nibbles, { sampleRate = 22050, loopFlag = 0 })
  local wave = decodeOrFail(bytes)
  Assert.equal(wave.format, 2)
  Assert.equal(wave.frames, 8)
  Assert.deepEqual(pcm16Samples(wave.pcm16le), { 1001, 1012, 1008, 1009, 1010, 1011, 1012, 1012 })
end

-- The greedy encoder round-trips exactly for constant signals (zero
-- difference nibbles are lossless; transient jumps are quantized).
function T.swav_round_trips_adpcm()
  local samples = {}
  for i = 1, 24 do
    samples[i] = 3000
  end
  local wave = decodeOrFail(SwarFixture.adpcm(samples))
  Assert.deepEqual(pcm16Samples(wave.pcm16le), samples)
end

-- Loop windows convert from the DS word units for every format; a one-shot
-- wave gets the full-range window and its loop flag stays false, a looping
-- wave carries the flag true.
function T.swav_converts_loop_windows()
  local pcm8 = decodeOrFail(SwarFixture.pcm8({ 1, 2, 3, 4, 5, 6, 7, 8 }, { loopFlag = 1, pnt = 1, len = 1 }))
  Assert.equal(pcm8.loopEnabled, true)
  Assert.deepEqual(pcm8.loop, { startFrame = 4, endFrame = 8 })

  local pcm16 = decodeOrFail(SwarFixture.pcm16({ 1, 2, 3, 4, 5, 6, 7, 8 }, { loopFlag = 1, pnt = 2, len = 2 }))
  Assert.deepEqual(pcm16.loop, { startFrame = 4, endFrame = 8 })

  local adpcm = decodeOrFail(SwarFixture.adpcmRaw(0, 0, string.rep("\0", 4), { loopFlag = 1, pnt = 1, len = 1 }))
  Assert.deepEqual(adpcm.loop, { startFrame = 0, endFrame = 8 })

  local withIntro = decodeOrFail(SwarFixture.adpcmRaw(0, 0, string.rep("\0", 12), { loopFlag = 1, pnt = 2, len = 2 }))
  Assert.equal(withIntro.frames, 24)
  Assert.deepEqual(withIntro.loop, { startFrame = 8, endFrame = 24 })

  local oneShot = decodeOrFail(SwarFixture.pcm8({ 1, 2, 3, 4, 5, 6, 7, 8 }, { loopFlag = 0 }))
  Assert.equal(oneShot.loopEnabled, false)
  Assert.deepEqual(oneShot.loop, { startFrame = 0, endFrame = 8 })
end

-- A member whose size does not match its pnt+len accounting is malformed.
function T.swav_rejects_size_mismatch()
  local bytes = SwarFixture.pcm8({ 1, 2, 3, 4 })
  local corrupted = bytes:sub(1, -2)
  decodeRejects(corrupted, "SWAV_SIZE_MISMATCH")
end

-- Formats outside PCM8/PCM16/ADPCM are unsupported.
function T.swav_rejects_unsupported_format()
  local bytes = SwarFixture.pcm8({ 1, 2, 3, 4 })
  local corrupted = string.char(3) .. bytes:sub(2)
  decodeRejects(corrupted, "SWAV_UNSUPPORTED_FORMAT")
end

-- A member shorter than its parameter header is truncated data.
function T.swav_rejects_truncated_member()
  decodeRejects("SWAV", "SWAV_TRUNCATED")
  local bytes = SwarFixture.pcm16({ 1, 2 })
  decodeRejects(bytes:sub(1, 11), "SWAV_TRUNCATED")
end

return { tests = T }
