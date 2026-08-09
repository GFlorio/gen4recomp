-- AnimationClip: the normalized, source-format-neutral animation contract.
-- A clip is the smallest unit gameplay and the player know: it has a frame
-- count, a category (joint / material / visibility), a free-form kind, and a
-- list of tracks that bindings map onto a concrete model. Everything below
-- `source` is opaque to the runtime: a vanilla clip compiled from an NSBCA
-- member and a future glTF animation must be indistinguishable here.
--
--   clip = {
--     id = "a106-12",                 unique clip identifier
--     name = "door_op",               source-format name (Nitro dict entry /
--                                     glTF animation name)
--     category = "joint"|"material"|"visibility",
--     kind = "trs"|"pattern"|"color"|...,   free-form, never dispatched on
--     frameCount = 8,                 number of frames (last key frame + 1)
--     tracks = { { target = t, channels = {...} }, ... },
--     semanticNames = { "door.open" },  optional engine-level animation roles
--     source = { type = "nitro"|"gltf", ... },  opaque provenance
--   }
--
-- Track target refs are the source-neutral key used by AnimationBinding:
-- joint/visibility tracks target a node index, material tracks a material
-- name. Joint tracks carry the channels "translation", "rotation", and
-- "scale"; visibility tracks carry "visible"; material channel shapes are
-- defined by their consumers. The runtime never decodes `source`; it is
-- carried for diagnostics, content-addressing, and modding tooling only.
--
-- `sample` is the format-neutral channel sampler: keys are { frame, value }
-- with `step` (hold the last key) or `linear` (interpolate between the
-- surrounding keys) interpolation, at fractional fixed-point frames (one
-- frame = FRAME_UNIT). Nitro clips do not use it -- they bring their own
-- curve semantics through their compiled evaluator -- but the shared
-- contract is tested here so the generic backend and future glTF clips rest
-- on one sampler. Linearly interpolated rotation channels are rebuilt by
-- the consumer with the engine's basis-vector orthonormalization, because a
-- per-cell matrix lerp is not itself a rotation. Pure domain module.

local Errors = require("libs.rom.src.Errors")

local AnimationClip = {}

-- Fixed-point frame unit: one frame is FRAME_UNIT, shared by every player
-- and sampler in the animation runtime (DS fixed point is 1.M.12).
AnimationClip.FRAME_UNIT = 4096

AnimationClip.CATEGORIES = { joint = true, material = true, visibility = true }
AnimationClip.INTERPOLATIONS = { step = true, linear = true }

local function isNonNegativeNumber(value)
  return type(value) == "number" and value >= 0 and value == value
end

-- Validate one track: a target plus channels whose keys are sorted
-- non-negative frames with non-nil values. Channel value shapes (3-vector,
-- 9-cell rotation, scalars, packed colors) are left to the consumers that
-- define them; this contract only guards the frame envelope.
local function validateTracks(tracks, context)
  for i, track in ipairs(tracks) do
    if track.target == nil then
      Errors.raise("ANIM_CLIP_TRACK_NO_TARGET",
        "track " .. i .. " of clip " .. context .. " has no target", { track = i })
    end
    if type(track.channels) ~= "table" or next(track.channels) == nil then
      Errors.raise("ANIM_CLIP_TRACK_NO_CHANNELS",
        "track " .. i .. " of clip " .. context .. " has no channels", { track = i })
    end
    for channelName, channel in pairs(track.channels) do
      if not AnimationClip.INTERPOLATIONS[channel.interpolation] then
        Errors.raise("ANIM_CLIP_BAD_INTERPOLATION",
          "channel " .. channelName .. " of clip " .. context
            .. " has unsupported interpolation " .. tostring(channel.interpolation),
          { track = i, channel = channelName })
      end
      if type(channel.keys) ~= "table" or #channel.keys == 0 then
        Errors.raise("ANIM_CLIP_CHANNEL_NO_KEYS",
          "channel " .. channelName .. " of clip " .. context
            .. " has no keys", { track = i, channel = channelName })
      end
      local previousFrame = -1
      for keyIndex, key in ipairs(channel.keys) do
        if not isNonNegativeNumber(key.frame) then
          Errors.raise("ANIM_CLIP_BAD_KEY_FRAME",
            "channel " .. channelName .. " of clip " .. context .. " has a bad key frame",
            { track = i, channel = channelName, key = keyIndex })
        end
        if key.frame <= previousFrame then
          Errors.raise("ANIM_CLIP_UNSORTED_KEYS",
            "channel " .. channelName .. " of clip " .. context
              .. " has unsorted key frames", { track = i, channel = channelName, key = keyIndex })
        end
        previousFrame = key.frame
        if key.value == nil then
          Errors.raise("ANIM_CLIP_KEY_NO_VALUE",
            "channel " .. channelName .. " of clip " .. context
              .. " has a key without a value", { track = i, channel = channelName, key = keyIndex })
        end
      end
    end
  end
end

-- Build a validated clip from a plain spec table. Raises a structured error on
-- any contract violation. Track tables are kept by reference (a clip is
-- immutable by convention); each track gains its zero-based `index` for
-- sampling.
function AnimationClip.new(spec)
  assert(type(spec) == "table", "AnimationClip.new requires a table")
  if not AnimationClip.CATEGORIES[spec.category] then
    Errors.raise("ANIM_CLIP_BAD_CATEGORY",
      "clip category must be joint, material, or visibility, got "
        .. tostring(spec.category), {})
  end
  if type(spec.id) ~= "string" or #spec.id == 0 then
    Errors.raise("ANIM_CLIP_NO_ID", "clip requires a non-empty id", {})
  end
  if type(spec.name) ~= "string" or #spec.name == 0 then
    Errors.raise("ANIM_CLIP_NO_NAME", "clip requires a non-empty name", {})
  end
  if not (type(spec.frameCount) == "number" and spec.frameCount >= 1
    and math.floor(spec.frameCount) == spec.frameCount) then
    Errors.raise("ANIM_CLIP_BAD_FRAME_COUNT",
      "clip frame count must be a positive integer, got " .. tostring(spec.frameCount), {})
  end
  if type(spec.tracks) ~= "table" or #spec.tracks == 0 then
    Errors.raise("ANIM_CLIP_NO_TRACKS", "clip " .. spec.id .. " has no tracks", {})
  end
  if spec.source ~= nil and type(spec.source) ~= "table" then
    Errors.raise("ANIM_CLIP_BAD_SOURCE", "clip source must be a table or nil", {})
  end
  if spec.semanticNames ~= nil then
    assert(type(spec.semanticNames) == "table", "semanticNames must be a table")
    for _, name in ipairs(spec.semanticNames) do
      assert(type(name) == "string" and #name > 0, "semantic names must be non-empty strings")
    end
  end

  validateTracks(spec.tracks, spec.id)
  for i, track in ipairs(spec.tracks) do track.index = i - 1 end

  return {
    id = spec.id,
    name = spec.name,
    category = spec.category,
    kind = spec.kind,
    frameCount = spec.frameCount,
    tracks = spec.tracks,
    semanticNames = spec.semanticNames or {},
    source = spec.source,
  }
end

-- Interpolate between two key values. Scalar values lerp arithmetically;
-- table values lerp component-wise, whether they are array-shaped (9-cell
-- rotations) or field-shaped ({x,y,z} vectors). `t` is a plain fraction in
-- 0..1.
local function lerpValue(a, b, t)
  if type(a) ~= "table" then return a + (b - a) * t end
  local out = {}
  if #a > 0 then
    assert(#a == #b, "interpolated key values must have equal shapes")
    for i = 1, #a do out[i] = a[i] + (b[i] - a[i]) * t end
  else
    for k, v in pairs(a) do
      assert(b[k] ~= nil, "interpolated key values must have equal shapes")
      out[k] = v + (b[k] - v) * t
    end
  end
  return out
end

-- Sample one channel of one track at `frameFx` (fixed-point; the fractional
-- part is used by linear interpolation). `trackIndex` is zero-based, like
-- every other index in the engine. The frame is clamped to the key range;
-- `step` holds the last key at or before the frame, `linear` interpolates
-- between the surrounding keys. Returns the key value.
function AnimationClip.sample(clip, trackIndex, channelName, frameFx)
  local track = assert(clip.tracks[trackIndex + 1],
    "track index " .. tostring(trackIndex) .. " out of range for clip " .. clip.id)
  local channel = assert(track.channels[channelName],
    "clip " .. clip.id .. " track " .. trackIndex .. " has no channel " .. tostring(channelName))
  local keys = channel.keys
  local frame = frameFx / AnimationClip.FRAME_UNIT

  if frame <= keys[1].frame then return keys[1].value end
  local last = keys[#keys]
  if frame >= last.frame then return last.value end

  local lower, upper
  for i = 1, #keys - 1 do
    if frame < keys[i + 1].frame then lower, upper = i, i + 1 break end
  end

  if channel.interpolation == "step" then return keys[lower].value end

  local a, b = keys[lower], keys[upper]
  local t = (frame - a.frame) / (b.frame - a.frame)
  return lerpValue(a.value, b.value, t)
end

return AnimationClip
