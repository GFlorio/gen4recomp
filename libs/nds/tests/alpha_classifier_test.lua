-- AlphaClassifier: material ordering classes follow the DS fragment alpha
-- contract (polygon alpha plus texture alpha usage) and polygon mode.
--
-- The tests verify the MIXED class and final-alpha-aware classification logic
-- driven by polygon mode and alpha usage, not format alone.

local Assert = require("tests.support.Assert")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")

local T = {}

local function au(hasZero, hasPartial, hasOpaque)
  return { hasZero = hasZero, hasPartial = hasPartial, hasOpaque = hasOpaque }
end

-- Baseline wireframe and translucent edges
function T.alpha_0_is_wireframe()
  Assert.equal(AlphaClassifier.classify(0, "modulation", 3, au(false, false, true)), "wireframe")
end

function T.alpha_1_is_translucent()
  Assert.equal(AlphaClassifier.classify(1, "modulation", 3, au(false, false, true)), "translucent")
end

function T.alpha_30_is_translucent()
  Assert.equal(AlphaClassifier.classify(30, "modulation", 3, au(false, false, true)), "translucent")
end

-- Alpha 31, modulation, texture without mixed fragments
function T.alpha_31_modulation_opaque_texture_is_opaque()
  Assert.equal(AlphaClassifier.classify(31, "modulation", 3, au(false, false, true)), "opaque")
end

function T.alpha_31_modulation_binary_zero_is_cutout()
  Assert.equal(AlphaClassifier.classify(31, "modulation", 7, au(true, false, true)), "cutout")
end

function T.alpha_31_modulation_partial_only_is_translucent()
  Assert.equal(AlphaClassifier.classify(31, "modulation", 3, au(false, true, false)), "translucent")
end

function T.alpha_31_modulation_zero_and_partial_is_translucent()
  Assert.equal(AlphaClassifier.classify(31, "modulation", 3, au(true, true, false)), "translucent")
end

-- Alpha 31, modulation, mixed alpha fragments -> MIXED
function T.alpha_31_modulation_partial_and_opaque_is_mixed()
  Assert.equal(AlphaClassifier.classify(31, "modulation", 3, au(false, true, true)), "mixed")
end

function T.alpha_31_modulation_all_three_alphas_is_mixed()
  Assert.equal(AlphaClassifier.classify(31, "modulation", 3, au(true, true, true)), "mixed")
end

-- MIXED with A3I5 and A5I3 formats, even though format is no longer the sole
-- rule.
function T.alpha_31_modulation_a3i5_with_mixed_alpha_is_mixed()
  Assert.equal(AlphaClassifier.classify(31, "modulation", 1, au(false, true, true)), "mixed")
end

function T.alpha_31_modulation_a5i3_with_mixed_alpha_is_mixed()
  Assert.equal(AlphaClassifier.classify(31, "modulation", 6, au(false, true, true)), "mixed")
end

-- DECAL tests protect the important final-alpha nuance.
--
-- DECAL polygon alpha 31 is always OPAQUE regardless of texture alpha
-- (final alpha is polygon alpha, not texture alpha).
function T.alpha_31_decal_with_zero_partial_opaque_is_opaque()
  Assert.equal(AlphaClassifier.classify(31, "decal", 3, au(true, true, true)), "opaque")
end

function T.alpha_31_decal_with_a3i5_is_opaque()
  Assert.equal(AlphaClassifier.classify(31, "decal", 1, au(true, true, true)), "opaque")
end

function T.alpha_31_decal_with_a5i3_is_opaque()
  Assert.equal(AlphaClassifier.classify(31, "decal", 6, au(true, true, true)), "opaque")
end

-- DECAL with polygon alpha below 31 is translucent (final alpha is polygon alpha)
function T.alpha_20_decal_is_translucent()
  Assert.equal(AlphaClassifier.classify(20, "decal", 1, au(true, true, true)), "translucent")
end

-- Untextured polygon alpha 31 is opaque
function T.alpha_31_untextured_is_opaque()
  Assert.equal(AlphaClassifier.classify(31, "modulation", 0, nil), "opaque")
end

-- Old format-based rule removed: A3I5/A5I3 alone no longer force translucent
-- when texture usage is checked. Format is still visible to the classifier but
-- the rule depends on alpha usage, not format.
function T.old_a3i5_force_translucent_rule_is_gone()
  -- A3I5 with only opaque alpha -> now OPAQUE, not translucent
  Assert.equal(AlphaClassifier.classify(31, "modulation", 1, au(false, false, true)), "opaque")
end

return { tests = T }
