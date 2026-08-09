-- AnimationClip: contract validation and the format-neutral channel sampler
-- (step/linear keys at fractional fixed-point frames).

local Assert = require("tests.support.Assert")
local AnimationClip = require("libs.engine.src.AnimationClip")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

local function clipSpec(overrides)
  local s = {
    id = "c1", name = "open", category = "joint", kind = "trs", frameCount = 8,
    tracks = {
      { target = 1, channels = { translation = { interpolation = "linear",
        keys = { { frame = 0, value = { x = 0, y = 0, z = 0 } },
          { frame = 7, value = { x = 4, y = 0, z = 0 } } } } } },
    },
  }
  for k, v in pairs(overrides or {}) do s[k] = v end
  return s
end

-- ---- validation ----

function T.rejects_bad_envelope()
  throwsCode("ANIM_CLIP_BAD_CATEGORY", function()
    return AnimationClip.new(clipSpec({ category = "light" }))
  end)
  throwsCode("ANIM_CLIP_NO_ID", function()
    return AnimationClip.new(clipSpec({ id = "" }))
  end)
  throwsCode("ANIM_CLIP_NO_NAME", function()
    return AnimationClip.new(clipSpec({ name = "" }))
  end)
  throwsCode("ANIM_CLIP_BAD_FRAME_COUNT", function()
    return AnimationClip.new(clipSpec({ frameCount = 0 }))
  end)
  throwsCode("ANIM_CLIP_BAD_FRAME_COUNT", function()
    return AnimationClip.new(clipSpec({ frameCount = 2.5 }))
  end)
  throwsCode("ANIM_CLIP_NO_TRACKS", function()
    return AnimationClip.new(clipSpec({ tracks = {} }))
  end)
  throwsCode("ANIM_CLIP_BAD_SOURCE", function()
    return AnimationClip.new(clipSpec({ source = "gltf" }))
  end)
end

function T.rejects_bad_tracks()
  throwsCode("ANIM_CLIP_TRACK_NO_TARGET", function()
    return AnimationClip.new(clipSpec({ tracks = { { channels = {} } } }))
  end)
  throwsCode("ANIM_CLIP_TRACK_NO_CHANNELS", function()
    return AnimationClip.new(clipSpec({ tracks = { { target = 1 } } }))
  end)
  throwsCode("ANIM_CLIP_CHANNEL_NO_KEYS", function()
    return AnimationClip.new(clipSpec({ tracks = { { target = 1, channels = {
      translation = { interpolation = "linear", keys = {} } } } } }))
  end)
  throwsCode("ANIM_CLIP_BAD_INTERPOLATION", function()
    return AnimationClip.new(clipSpec({ tracks = { { target = 1, channels = {
      translation = { interpolation = "slerp", keys = { { frame = 0, value = 1 } } } } } } }))
  end)
  throwsCode("ANIM_CLIP_UNSORTED_KEYS", function()
    return AnimationClip.new(clipSpec({ tracks = { { target = 1, channels = {
      translation = { interpolation = "step",
        keys = { { frame = 2, value = 1 }, { frame = 1, value = 0 } } } } } } }))
  end)
  throwsCode("ANIM_CLIP_KEY_NO_VALUE", function()
    return AnimationClip.new(clipSpec({ tracks = { { target = 1, channels = {
      translation = { interpolation = "step", keys = { { frame = 0 } } } } } } }))
  end)
end

function T.new_sets_zero_based_track_indices()
  local clip = AnimationClip.new(clipSpec({
    tracks = { clipSpec().tracks[1], clipSpec().tracks[1] },
  }))
  Assert.equal(clip.tracks[1].index, 0)
  Assert.equal(clip.tracks[2].index, 1)
end

-- ---- sampling ----

local function sample(clip, trackIndex, channel, frameFx)
  return AnimationClip.sample(clip, trackIndex, channel, frameFx)
end

function T.step_holds_the_last_key()
  local clip = AnimationClip.new(clipSpec({
    tracks = { { target = 1, channels = { translation = { interpolation = "step",
      keys = { { frame = 0, value = { x = 0, y = 0, z = 0 } },
        { frame = 4, value = { x = 9, y = 0, z = 0 } } } } } } },
  }))
  Assert.equal(sample(clip, 0, "translation", 0).x, 0)
  Assert.equal(sample(clip, 0, "translation", 2 * 4096).x, 0, "holds until the next key")
  Assert.equal(sample(clip, 0, "translation", 4 * 4096).x, 9)
  Assert.equal(sample(clip, 0, "translation", 100 * 4096).x, 9, "clamps past the last key")
end

function T.linear_interpolates_between_keys()
  local clip = AnimationClip.new(clipSpec({
    tracks = { { target = 1, channels = { translation = { interpolation = "linear",
      keys = { { frame = 0, value = { x = 0, y = 0, z = 0 } },
        { frame = 8, value = { x = 8, y = 0, z = 0 } } } } } } },
  }))
  Assert.equal(sample(clip, 0, "translation", 4 * 4096).x, 4)
  -- Fractional fixed-point frames participate in linear interpolation.
  Assert.near(sample(clip, 0, "translation", 2.5 * 4096).x, 2.5, 1e-9)
  -- Frames before the first key take the first key.
  Assert.equal(sample(clip, 0, "translation", -4096).x, 0)
end

function T.linear_interpolates_scalar_values()
  local clip = AnimationClip.new(clipSpec({
    tracks = { { target = "mat", channels = { diffuse = { interpolation = "linear",
      keys = { { frame = 0, value = 0 }, { frame = 4, value = 100 } } } } } },
  }))
  Assert.equal(sample(clip, 0, "diffuse", 2 * 4096), 50)
end

function T.sample_asserts_bad_access()
  local clip = AnimationClip.new(clipSpec())
  local ok = pcall(sample, clip, 5, "translation", 0)
  Assert.isFalse(ok, "out-of-range track index is a programming error")
  ok = pcall(sample, clip, 0, "rotation", 0)
  Assert.isFalse(ok, "missing channel is a programming error")
end

return T
