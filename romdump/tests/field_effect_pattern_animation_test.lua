local Assert = require("tests.support.Assert")
local FieldEffectPatternAnimation = require("romdump.src.digest.FieldEffectPatternAnimation")

local T = { tests = {} }

T.tests["decodes source texture pattern key schedules"] = function()
  local bytes = string.char(4, 0, 0, 0, 0, 0, 4, 0, 8, 0, 12, 0, 0, 1, 2, 3)
  local decoded = assert(FieldEffectPatternAnimation.decode(bytes))
  Assert.equal(decoded.frameCount, 13)
  Assert.equal(#decoded.keys, 4)
  Assert.equal(decoded.keys[3].frame, 8)
  Assert.equal(decoded.keys[4].texIdx, 3)
  Assert.equal(decoded.keys[1].plttIdx, 0xFF)
end

T.tests["rejects a truncated source texture pattern"] = function()
  local decoded, err = FieldEffectPatternAnimation.decode(string.char(1, 0, 0, 0))
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, "FIELD_EFFECT_ANIMATION_INVALID")
end

T.tests["rejects a non-monotonic source texture pattern"] = function()
  local bytes = string.char(2, 0, 0, 0, 4, 0, 4, 0, 0, 1)
  local decoded, err = FieldEffectPatternAnimation.decode(bytes)
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, "FIELD_EFFECT_ANIMATION_INVALID")
end

return T
