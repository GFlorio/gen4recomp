-- CompiledNsbtpSampler: the runtime sampler over a compiled NSBTP clip
-- payload (NsbtpClipCompiler, digest side). The engine never touches NSBTP
-- bytes; this module reproduces NNSi_G3dGetTexPatAnmFV (pokediamond
-- NNS_G3D_res_struct_acce.s) over the compiled keys and must stay identical
-- to Nsbtp.keyAt -- the cross-check tests compare both paths on every
-- fixture.
--
-- Input: a clip whose `compiled` payload is
--
--   { textureNames = { ... }, paletteNames = { ... },
--     targets = { { index, name, rate, keys = {
--       { frame, texIdx, plttIdx } } } } }
--
-- The arrays are the counts: the payload carries no keyCount/
-- numTextures/numPalettes, so the sampler reads #keys/#textureNames/
-- #paletteNames.
--
-- The calc consumes the integer frame (frame >> 12; the caller drops the
-- fractional part before sampling), and returns the active key: start at
-- (rate * frame) >> 12, walk back while key.frame >= frame (floor 0) and
-- forward while the next key's frame <= frame. A plttIdx of 0xFF means the
-- key carries no palette change. Pure domain module.

local FixedPoint = require("libs.math.src.FixedPoint")

local CompiledNsbtpSampler = {}

local FRAME_UNIT = FixedPoint.FX32_SCALE

-- The active key for the integer `frame` (see Nsbtp.keyAt for the exact
-- walk semantics). Returns { frame, texIdx, plttIdx }.
function CompiledNsbtpSampler.keyAt(clip, targetIndex, frameFx)
  assert(type(clip) == "table" and clip.compiled ~= nil, "CompiledNsbtpSampler requires a clip with a compiled payload")
  local target = assert(
    clip.compiled.targets[targetIndex + 1],
    "target index " .. tostring(targetIndex) .. " out of range for clip " .. clip.id
  )
  local frame = math.floor(frameFx / FRAME_UNIT)
  local keyCount = #target.keys
  local i = math.floor(target.rate * frame / FRAME_UNIT)
  if i >= keyCount then
    i = keyCount - 1
  end
  while i > 0 and target.keys[i].frame >= frame do
    i = i - 1
  end
  while i + 1 < keyCount and target.keys[i + 2].frame <= frame do
    i = i + 1
  end
  return target.keys[i + 1]
end

return CompiledNsbtpSampler
