local Assert = require("tests.support.Assert")
local FieldEffectPatternAnimation = require("romdump.src.digest.field.FieldEffectPatternAnimation")

local T = { tests = {} }
local unpack = table.unpack or unpack

local function resource(frames, textures, palettes)
  local bytes = { string.char(#frames, 0, 0, 0) }
  for _, frame in ipairs(frames) do
    bytes[#bytes + 1] = string.char(frame % 256, math.floor(frame / 256))
  end
  bytes[#bytes + 1] = string.char(unpack(textures))
  bytes[#bytes + 1] = string.char(unpack(palettes))
  return table.concat(bytes)
end

T.tests["decodes paired source selector schedules"] = function()
  local bytes = resource({ 0, 4, 8, 12 }, { 3, 2, 1, 0 }, { 9, 8, 7, 6 })
  local decoded = assert(FieldEffectPatternAnimation.decode(bytes))
  Assert.equal(#decoded.keys, 4)
  Assert.equal(decoded.keys[1].frame, 0)
  Assert.equal(decoded.keys[1].texIdx, 3)
  Assert.equal(decoded.keys[1].plttIdx, 9)
  Assert.equal(decoded.keys[3].frame, 8)
  Assert.equal(decoded.keys[3].texIdx, 1)
  Assert.equal(decoded.keys[3].plttIdx, 7)
  Assert.equal(decoded.keys[4].texIdx, 0)
  Assert.equal(decoded.keys[4].plttIdx, 6)
end

T.tests["rejects a resource truncated before the second selector stream"] = function()
  local bytes = resource({ 0, 4, 8, 12 }, { 3, 2, 1, 0 }, {})
  local decoded, err = FieldEffectPatternAnimation.decode(bytes)
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, "FIELD_EFFECT_ANIMATION_INVALID")
end

T.tests["rejects a resource truncated inside the second selector stream"] = function()
  local bytes = resource({ 0, 4, 8, 12 }, { 3, 2, 1, 0 }, { 9, 8, 7 })
  local decoded, err = FieldEffectPatternAnimation.decode(bytes)
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, "FIELD_EFFECT_ANIMATION_INVALID")
end

T.tests["rejects non-monotonic source frames"] = function()
  local bytes = resource({ 0, 4, 4, 12 }, { 0, 1, 2, 3 }, { 4, 5, 6, 7 })
  local decoded, err = FieldEffectPatternAnimation.decode(bytes)
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, "FIELD_EFFECT_ANIMATION_INVALID")
end

return T
