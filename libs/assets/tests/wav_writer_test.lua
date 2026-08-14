-- Generic PCM16 WAV encoding for generated UI effects: a canonical RIFF/WAVE
-- container with a single data chunk. The producer renders decoded HGSS
-- sound effects to PCM16; this module owns only the container, never
-- Nintendo/SDAT interpretation.

local Assert = require("tests.support.Assert")
local WavWriter = require("libs.assets.src.WavWriter")

local T = {}

local function u16le(data, offset)
  return string.byte(data, offset + 1) + string.byte(data, offset + 2) * 256
end
local function u32le(data, offset)
  return string.byte(data, offset + 1)
    + string.byte(data, offset + 2) * 256
    + string.byte(data, offset + 3) * 65536
    + string.byte(data, offset + 4) * 16777216
end

function T.writes_a_canonical_pcm16_wav()
  local samples = string.char(0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80)
  local wav = assert(WavWriter.encode(22050, 1, samples))
  Assert.equal(wav:sub(1, 4), "RIFF")
  Assert.equal(wav:sub(9, 12), "WAVE")
  Assert.equal(wav:sub(13, 16), "fmt ")
  Assert.equal(u32le(wav, 16), 16, "PCM fmt chunk size")
  Assert.equal(u16le(wav, 20), 1, "PCM format tag")
  Assert.equal(u16le(wav, 22), 1, "mono")
  Assert.equal(u32le(wav, 24), 22050, "sample rate")
  Assert.equal(u32le(wav, 28), 44100, "byte rate = rate * block align")
  Assert.equal(u16le(wav, 32), 2, "block align")
  Assert.equal(u16le(wav, 34), 16, "bits per sample")
  Assert.equal(wav:sub(37, 40), "data")
  Assert.equal(u32le(wav, 40), 6, "data size")
  Assert.equal(wav:sub(45), samples, "samples follow the data header")
  Assert.equal(u32le(wav, 4), 36 + 6, "RIFF size covers fmt + data")
end

function T.stereo_and_odd_rates_are_preserved()
  local wav = assert(WavWriter.encode(16000, 2, string.rep("\0", 8)))
  Assert.equal(u16le(wav, 22), 2, "stereo")
  Assert.equal(u32le(wav, 28), 64000, "byte rate = rate * 4")
  Assert.equal(u16le(wav, 32), 4, "stereo block align")
end

function T.invalid_shapes_are_rejected()
  local out, err = WavWriter.encode(0, 1, "\0\0")
  Assert.isNil(out)
  Assert.equal(assert(err).code, "WAV_SHAPE_INVALID")
  local out2, err2 = WavWriter.encode(22050, 3, "\0\0")
  Assert.isNil(out2)
  Assert.equal(assert(err2).code, "WAV_SHAPE_INVALID")
  local out3, err3 = WavWriter.encode(22050, 1, "\0")
  Assert.isNil(out3)
  Assert.equal(assert(err3).code, "WAV_SHAPE_INVALID")
end

return { tests = T }
