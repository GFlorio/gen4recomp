-- CompiledNsbmaSampler: the runtime sampler over a compiled NSBMA clip
-- payload (NsbmaClipCompiler, digest side). The engine never touches NSBMA
-- bytes; this module reproduces the Nitro material-color sampling math over
-- the compiled channels and must stay bit-identical to Nsbma.sample -- the
-- cross-check tests sample every fixture through both paths and require
-- equal results.
--
-- Input: a clip whose `compiled` payload is
--
--   { targets = { { index, name, channels = {
--       diffuse, ambient, specular, emission, alpha } } } }
--
-- where each channel is
--   { source = "constant", value = n }    -- value = (flag >> 16) & 0xFFFF
--   { source = "curve", rate = 1|2|4, limit, keys = { ... } }
--     -- color keys raw u16 RGB555, alpha keys raw u8 (0..31)
--
-- The result carries the raw component values (15-bit colors, 0..31
-- alpha); the material evaluator packs them into the effective material
-- colors and polygon alpha. The compiler emits all five channels with a
-- source vocabulary of {constant, curve}, so a hand-written record with a
-- missing channel or any other source is malformed and raises
-- ANIM_NSBMA_BAD_CHANNEL rather than taking the implicit curve path.
-- Pure domain module.

local AnimationClip = require("libs.assets.src.AnimationClip")
local Errors = require("libs.errors.src.Errors")

local CompiledNsbmaSampler = {}

local FRAME_UNIT = AnimationClip.FRAME_UNIT

local function asr(value, bits)
  return math.floor(value / 2 ^ bits)
end

-- 15-bit RGB555 channel masks, as the asm's 0x7C1F (B+R) and 0x3E0 (G)
-- constants keep the per-channel averages clean.
local function brOf(v)
  return v % 32 + (v % 32768 - v % 1024)
end
local function gOf(v)
  return v % 1024 - v % 32
end

local function avgColor(a, b)
  return asr(gOf(a) + gOf(b), 1) + asr(brOf(a) + brOf(b), 1)
end

local function weightedColor(a, b)
  return asr(3 * gOf(a) + gOf(b), 2) + asr(3 * brOf(a) + brOf(b), 2)
end

-- The shared odd-frame index logic; `isAlpha` selects u8 keys without the
-- color-channel averaging, exactly like the decoder's sampleKeys.
local function sampleKeys(chan, frame)
  local isAlpha = chan.isAlpha
  local keys = chan.keys
  local function single(index)
    return keys[index + 1]
  end
  local function pair(index)
    local a = single(index)
    local b = single(index + 1)
    return isAlpha and asr(a + b, 1) or avgColor(a, b)
  end
  local function weighted(index, index2)
    local a = single(index)
    local b = single(index2)
    return isAlpha and asr(3 * a + b, 2) or weightedColor(a, b)
  end
  if chan.rate == 2 then
    if frame % 2 == 1 then
      if frame > chan.limit then
        return single(math.floor(chan.limit / 2) + 1)
      end
      return pair(math.floor(frame / 2))
    end
    return single(math.floor(frame / 2))
  elseif chan.rate == 4 then
    if frame % 4 ~= 0 then
      if frame > chan.limit then
        return single(frame % 4 + math.floor(chan.limit / 4))
      end
      if frame % 4 == 2 then
        return pair(math.floor(frame / 4))
      end
      if frame % 4 == 1 then
        return weighted(math.floor(frame / 4), math.floor(frame / 4) + 1)
      end
      return weighted(math.floor(frame / 4) + 1, math.floor(frame / 4))
    end
    return single(math.floor(frame / 4))
  end
  return single(frame)
end

-- The five material registers the compiler always emits, in their authored
-- order (the sampler's per-call channel iteration).
local CHANNEL_NAMES = { "diffuse", "ambient", "specular", "emission", "alpha" }

-- Sample one target of a compiled NSBMA clip at `frameFx` (the calc uses
-- the integer frame, clamped into [0, numFrame - 1]). Returns
-- { diffuse, ambient, specular, emission, alpha } as raw values (15-bit
-- RGB555 colors, 0..31 alpha), constants as stored.
function CompiledNsbmaSampler.sample(clip, targetIndex, frameFx)
  assert(type(clip) == "table" and clip.compiled ~= nil, "CompiledNsbmaSampler requires a clip with a compiled payload")
  local target = assert(
    clip.compiled.targets[targetIndex + 1],
    "target index " .. tostring(targetIndex) .. " out of range for clip " .. clip.id
  )
  local frame = math.floor(frameFx / FRAME_UNIT)
  if frame >= clip.frameCount then
    frame = clip.frameCount - 1
  end
  if frame < 0 then
    frame = 0
  end

  local out = {}
  for _, name in ipairs(CHANNEL_NAMES) do
    local chan = target.channels[name]
    if not chan or (chan.source ~= "constant" and chan.source ~= "curve") then
      Errors.raise(
        "ANIM_NSBMA_BAD_CHANNEL",
        "compiled NSBMA clip "
          .. tostring(clip.id)
          .. " target "
          .. tostring(targetIndex)
          .. " channel "
          .. name
          .. " source is neither constant nor curve",
        { clip = clip.id, targetIndex = targetIndex, channel = name }
      )
    end
    if chan.source == "constant" then
      out[name] = chan.value
    else
      out[name] = sampleKeys(chan, frame)
    end
  end
  return out
end

return CompiledNsbmaSampler
