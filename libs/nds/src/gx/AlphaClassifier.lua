-- The alpha-class contract of a compiled batch: classification of the
-- effective polygon alpha, polygon mode, and texture's alpha usage into one of
-- five ordering classes, plus the alpha vocabulary shared by the digest
-- compilers and the runtime. Follows the DS fragment alpha contract: the final
-- composed alpha is authoritative. Polygon alpha below 31 is translucent.
-- DECAL at polygon alpha 31 is opaque (texture alpha irrelevant). MODULATE at
-- polygon alpha 31 with mixed texture alpha (opaque and partial) is split into
-- opaque and translucent subpasses. Pure domain module; no LÖVE.

local FixedPoint = require("libs.math.src.FixedPoint")

local AlphaClassifier = {}

-- Bumped whenever the classification rules change in a cache-breaking way.
local VERSION = "alpha-classifier-v2"

-- The five alpha classes and the strings that serialize into compiled batch
-- records; every production and comparison site uses a named constant.
AlphaClassifier.OPAQUE = "opaque"
AlphaClassifier.TRANSLUCENT = "translucent"
AlphaClassifier.CUTOUT = "cutout"
AlphaClassifier.WIREFRAME = "wireframe"
AlphaClassifier.MIXED = "mixed"

-- Classify an effective polygon state against a texture and polygon mode.
-- `polygonMode` is a string ("decal" or "modulation" per DS semantics).
-- `textureFormat` is the raw NSBTX format (0 for untextured); `alphaUsage`
-- comes from TextureDecoder.decode (nil when untextured). Classification is
-- final-alpha-aware: a MODULATE polygon at alpha 31 with mixed texture alpha
-- (both opaque and partial texels) returns MIXED; DECAL at alpha 31 always
-- returns OPAQUE regardless of texture alpha distribution.
function AlphaClassifier.classify(polygonAlpha, polygonMode, _, alphaUsage)
  if polygonAlpha == 0 then
    return AlphaClassifier.WIREFRAME
  end

  -- Any nonzero alpha below 31 cannot produce an opaque final alpha.
  if polygonAlpha < FixedPoint.RGB5_MAX then
    return AlphaClassifier.TRANSLUCENT
  end

  -- DECAL final alpha is polygon alpha, not texture alpha.
  if polygonMode == "decal" then
    return AlphaClassifier.OPAQUE
  end

  -- For MODULATE at polygon alpha 31, final alpha equals texture alpha.
  if alphaUsage and alphaUsage.hasPartial then
    if alphaUsage.hasOpaque then
      return AlphaClassifier.MIXED
    end
    return AlphaClassifier.TRANSLUCENT
  end

  if alphaUsage and alphaUsage.hasZero then
    return AlphaClassifier.CUTOUT
  end

  return AlphaClassifier.OPAQUE
end

AlphaClassifier.VERSION = VERSION

return AlphaClassifier
