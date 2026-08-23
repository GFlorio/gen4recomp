local Assert = require("tests.support.Assert")
local TextSpeedPolicy = require("libs.engine.src.TextSpeedPolicy")

local T = {}

function T.exposes_one_strict_policy_for_every_field_speed()
  Assert.deepEqual(TextSpeedPolicy.forSpeed("slow"), {
    interGlyphDelay = 7,
    glyphBudget = 1,
    abAcceleration = true,
  })
  Assert.deepEqual(TextSpeedPolicy.forSpeed("mid"), {
    interGlyphDelay = 3,
    glyphBudget = 1,
    abAcceleration = true,
  })
  Assert.deepEqual(TextSpeedPolicy.forSpeed("fast"), {
    interGlyphDelay = 0,
    glyphBudget = 1,
    abAcceleration = true,
  })
  Assert.deepEqual(TextSpeedPolicy.forSpeed("fastest"), {
    interGlyphDelay = 0,
    glyphBudget = 2,
    abAcceleration = false,
  })
end

function T.rejects_unknown_speed()
  Assert.throws(function()
    TextSpeedPolicy.forSpeed("turbo")
  end)
end

return { tests = T }
