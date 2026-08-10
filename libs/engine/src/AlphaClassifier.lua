-- Classify a compiled batch into one of four alpha ordering classes based on
-- the effective polygon alpha and the bound texture's alpha usage. Follows the
-- DS fragment alpha contract: polygon alpha below 31 is translucent, A3I5/A5I3
-- textures are always translucent, binary zero-alpha textures are cutout, and
-- polygon alpha zero marks a wireframe draw rather than an invisible filled
-- polygon. Pure domain module; no LÖVE.

local AlphaClassifier = {}

-- Bumped whenever the classification rules change in a cache-breaking way.
local VERSION = "alpha-classifier-v1"

-- Classify an effective polygon state against a texture. `textureFormat` is the
-- raw NSBTX format (0 for untextured); `alphaUsage` comes from
-- TextureDecoder.decode (nil when untextured).
function AlphaClassifier.classify(polygonAlpha, textureFormat, alphaUsage)
  if polygonAlpha == 0 then
    return "wireframe"
  end
  if polygonAlpha < 31 then
    return "translucent"
  end
  if textureFormat == 1 or textureFormat == 6 then
    return "translucent"
  end
  if alphaUsage and alphaUsage.hasZero then
    return "cutout"
  end
  return "opaque"
end

AlphaClassifier.VERSION = VERSION

return AlphaClassifier
