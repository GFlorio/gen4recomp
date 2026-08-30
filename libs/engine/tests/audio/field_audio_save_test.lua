local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldAudioSave = require("libs.engine.src.audio.FieldAudioSave")

local T = {}
local context = { audioSequenceIds = { [7] = true } }

function T.nil_and_indexed_overrides_are_valid()
  Assert.notNil(FieldAudioSave.validate({}, context))
  Assert.equal(assert(FieldAudioSave.validate({ fieldMusicOverride = 7 }, context)).fieldMusicOverride, 7)
end

function T.unknown_non_integer_and_extra_audio_state_are_rejected()
  for _, record in ipairs({
    { fieldMusicOverride = 8 },
    { fieldMusicOverride = 7.5 },
    { fieldMusicOverride = "7" },
    { unexpected = true },
  }) do
    local valid, err = FieldAudioSave.validate(record, context)
    Assert.isNil(valid)
    Assert.isTrue(Errors.is(err))
  end
end

return { tests = T }
