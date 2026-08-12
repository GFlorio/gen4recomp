-- AnimationClip: the nitro clip record contract. A clip is the record the
-- field runtime and the digest share -- id, name, category (joint or
-- material), a free-form kind, frameCount, tracks (one target per track),
-- semanticNames, opaque provenance, and the compiled payload the samplers
-- consume -- plus the shared door-role vocabulary. The generic channel-sampler
-- surface is cut: Nitro clips bring their own compiled curve semantics (the
-- compiled.* payload), no caller uses AnimationClip.sample, so there is no
-- sample(), no INTERPOLATIONS, and no channel-key validation. Track tables and
-- the compiled payload are retained by reference and NEVER mutated. Field
-- visibility animation does not exist (the corpus has no NSBVA members and the
-- format was deleted), so the category vocabulary is joint and material.
-- Pure domain module.

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
    id = "c1",
    name = "open",
    category = "joint",
    kind = "trs",
    frameCount = 8,
    -- The compiled payload is required by contract; an empty table suffices
    -- for constructor fixtures (the samplers touch compiled only when the
    -- clip actually plays through them).
    compiled = {},
    tracks = {
      {
        target = 1,
        channels = {
          translation = {
            interpolation = "linear",
            keys = {
              { frame = 0, value = { x = 0, y = 0, z = 0 } },
              { frame = 7, value = { x = 4, y = 0, z = 0 } },
            },
          },
        },
      },
    },
  }
  for k, v in pairs(overrides or {}) do
    s[k] = v
  end
  return s
end

-- ---- validation ----

function T.rejects_bad_envelope()
  throwsCode("ANIM_CLIP_BAD_CATEGORY", function()
    return AnimationClip.new(clipSpec({ category = "light" }))
  end)
  throwsCode("ANIM_CLIP_BAD_CATEGORY", function()
    return AnimationClip.new(clipSpec({ category = "visibility" }))
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
    return AnimationClip.new(clipSpec({ source = 42 }))
  end)
end

function T.categories_are_joint_and_material_only()
  Assert.equal(AnimationClip.CATEGORIES.joint, true)
  Assert.equal(AnimationClip.CATEGORIES.material, true)
  Assert.isNil(AnimationClip.CATEGORIES.visibility, "no field visibility animation exists")
end

function T.rejects_tracks_without_a_target()
  throwsCode("ANIM_CLIP_TRACK_NO_TARGET", function()
    return AnimationClip.new(clipSpec({ tracks = { { channels = {} } } }))
  end)
end

-- The generic sampler surface is cut: AnimationClip.sample has no caller
-- (Nitro clips sample through their compiled payload), so the interpolation
-- machinery it existed for is gone too.
function T.the_generic_sampler_is_cut()
  Assert.isNil(AnimationClip.sample, "no caller uses the generic sampler")
end

function T.the_interpolation_vocabulary_is_cut()
  Assert.isNil(AnimationClip.INTERPOLATIONS)
end

-- Channels are opaque to the clip contract: the step/linear key envelope was
-- the generic sampler's machinery, and Nitro clips carry their own compiled
-- curve semantics. A track needs only its target.
function T.a_track_needs_only_its_target()
  local clip = AnimationClip.new(clipSpec({ tracks = { { target = 1 } } }))
  Assert.equal(clip.tracks[1].target, 1)
end

function T.channels_are_opaque_to_the_clip_contract()
  local clip = AnimationClip.new(clipSpec({
    tracks = {
      {
        target = 1,
        channels = {
          diffuse = { interpolation = "slerp", keys = { { frame = 0, value = 0x203C } } },
        },
      },
    },
  }))
  Assert.equal(clip.tracks[1].target, 1)
end

-- The compiled payload is the samplers' whole curve semantics: a clip without
-- it cannot be sampled, so the constructor rejects it instead of returning a
-- record that carries no compiled key.
function T.new_requires_the_compiled_payload()
  -- A nil override cannot be expressed through clipSpec (pairs drops nil
  -- values), so the payload is stripped explicitly like the descriptor tests do.
  local spec = clipSpec()
  spec.compiled = nil
  throwsCode("ANIM_CLIP_NO_COMPILED", function()
    return AnimationClip.new(spec)
  end)
  throwsCode("ANIM_CLIP_NO_COMPILED", function()
    return AnimationClip.new(clipSpec({ compiled = "not-a-table" }))
  end)
end

-- The constructor keeps the opaque payload by reference: the samplers read
-- the same compiled table the caller built, and nothing copies or re-shapes it.
function T.new_preserves_the_compiled_payload_by_reference()
  local compiled = { rotData = {}, targets = {} }
  local clip = AnimationClip.new(clipSpec({ compiled = compiled }))
  Assert.isTrue(clip.compiled == compiled, "the compiled payload is retained by reference")
end

-- Track tables are kept by reference and never written: the old sampler's
-- zero-based `index` bookkeeping mutated caller-owned data.
function T.new_never_mutates_the_callers_tracks()
  local track = {
    target = 1,
    channels = {
      translation = { interpolation = "step", keys = { { frame = 0, value = { x = 0, y = 0, z = 0 } } } },
    },
  }
  local spec = clipSpec({ tracks = { track } })
  local clip = AnimationClip.new(spec)
  Assert.isTrue(clip.tracks[1] == track, "the track table is retained by reference")
  Assert.isNil(track.index, "the caller's track table is never written")
  Assert.isNil(spec.tracks[1].index)
end

-- The semantic animation roles gameplay and the digest share: the one owner
-- for the door open/close vocabulary, and the fixed-point frame unit every
-- player and sampler in the animation runtime uses.
function T.roles_and_frame_unit_are_the_shared_vocabulary()
  Assert.equal(AnimationClip.ROLES.DOOR_OPEN, "door.open")
  Assert.equal(AnimationClip.ROLES.DOOR_CLOSE, "door.close")
  Assert.equal(AnimationClip.FRAME_UNIT, 4096)
end

return T
