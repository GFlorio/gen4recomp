local Assert = require("tests.support.Assert")
local InstrumentSelector = require("libs.nds.src.nitro.sound.InstrumentSelector")
local AudioFixture = require("tests.support.AudioFixture")

local T = {}

function T.selects_direct_split_drum_and_dummy_voices()
  local bank = AudioFixture.bank(12, "BANK_TEST")
  local split = bank.instruments[1]
  local drums = bank.instruments[2]

  Assert.equal(InstrumentSelector.selectVoice(bank.instruments[0], 60), bank.instruments[0].voice)
  Assert.equal(InstrumentSelector.selectVoice(split, 59), split.ranges[1].voice)
  Assert.equal(InstrumentSelector.selectVoice(split, 60), split.ranges[2].voice)
  Assert.isNil(InstrumentSelector.selectVoice(split, -1))
  Assert.equal(InstrumentSelector.selectVoice(drums, 35), drums.voices[1])
  Assert.equal(InstrumentSelector.selectVoice(drums, 36), drums.voices[2])
  Assert.isNil(InstrumentSelector.selectVoice(drums, 37))

  bank.instruments[0].voice = { kind = "dummy" }
  Assert.isNil(InstrumentSelector.selectVoice(bank.instruments[0], 60))

  split.ranges[1].voice = { kind = "dummy" }
  Assert.isNil(InstrumentSelector.selectVoice(split, 59))
  drums.voices[1] = { kind = "dummy" }
  Assert.isNil(InstrumentSelector.selectVoice(drums, 35))
end

return { tests = T }
