-- AlphaClassifier: material ordering classes follow the DS fragment alpha
-- contract (polygon alpha plus texture alpha usage).

local Assert = require("tests.support.Assert")
local AlphaClassifier = require("src.import.AlphaClassifier")

local T = {}

local function au(hasZero, hasPartial, hasOpaque)
  return { hasZero = hasZero, hasPartial = hasPartial, hasOpaque = hasOpaque }
end

function T.alpha_31_no_alpha_texture_is_opaque()
  Assert.equal(AlphaClassifier.classify(31, 3, au(false, false, true)), "opaque")
end

function T.alpha_31_binary_zero_alpha_texture_is_cutout()
  Assert.equal(AlphaClassifier.classify(31, 7, au(true, false, true)), "cutout")
end

function T.alpha_31_a3i5_is_translucent()
  Assert.equal(AlphaClassifier.classify(31, 1, au(true, true, true)), "translucent")
end

function T.alpha_31_a5i3_is_translucent()
  Assert.equal(AlphaClassifier.classify(31, 6, au(true, true, true)), "translucent")
end

function T.alpha_1_and_30_are_translucent()
  Assert.equal(AlphaClassifier.classify(1, 3, au(false, false, true)), "translucent")
  Assert.equal(AlphaClassifier.classify(30, 3, au(false, false, true)), "translucent")
end

function T.alpha_0_is_wireframe()
  Assert.equal(AlphaClassifier.classify(0, 3, au(false, false, true)), "wireframe")
end

function T.untextured_alpha_31_is_opaque()
  Assert.equal(AlphaClassifier.classify(31, 0, nil), "opaque")
end

function T.has_a_version()
  Assert.equal(type(AlphaClassifier.VERSION), "string")
end

return T
