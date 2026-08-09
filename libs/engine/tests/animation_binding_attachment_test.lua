-- AnimationBinding / AnimationAttachment / ModelAnimationState: the
-- loading-time mapping and the per-instance attachment groups.

local Assert = require("tests.support.Assert")
local AnimationClip = require("libs.engine.src.AnimationClip")
local AnimationBinding = require("libs.engine.src.AnimationBinding")
local AnimationAttachment = require("libs.engine.src.AnimationAttachment")
local AnimationPlayer = require("libs.engine.src.AnimationPlayer")
local ModelAnimationState = require("libs.engine.src.ModelAnimationState")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

local function jointClip()
  return AnimationClip.new({
    id = "clip:jnt", name = "joint", category = "joint", kind = "trs",
    frameCount = 8,
    tracks = {
      { target = 3, channels = { translation = { interpolation = "step",
        keys = { { frame = 0, value = { x = 1, y = 0, z = 0 } } } } } },
      { target = 5, channels = { rotation = { interpolation = "linear",
        keys = { { frame = 0, value = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } } } } } },
    },
  })
end

local function materialClip()
  return AnimationClip.new({
    id = "clip:mat", name = "material", category = "material", kind = "color",
    frameCount = 4,
    tracks = {
      { target = "door", channels = { diffuse = { interpolation = "step",
        keys = { { frame = 0, value = 0x203C } } } } },
    },
  })
end

-- ---- AnimationBinding ----

function T.binding_maps_and_resolves()
  local clip = jointClip()
  local binding = AnimationBinding.new(clip, "model:1", { [3] = 3, [5] = 5 })
  Assert.equal(binding.modelKey, "model:1")
  Assert.equal(binding:modelIndex(3), 3)
  Assert.equal(binding:modelIndex(5), 5)
  Assert.isNil(binding:modelIndex(99), "unmapped targets resolve to nil")
  Assert.equal(binding:mappedTargetCount(), 2)
  Assert.equal(binding.clip, clip)
end

function T.binding_permits_partial_mapping()
  local clip = jointClip()
  local binding = AnimationBinding.new(clip, "model:1", { [3] = 3 })
  Assert.equal(binding:mappedTargetCount(), 1)
  Assert.isNil(binding:modelIndex(5))
end

function T.binding_zero_mapped_targets_raises()
  local clip = jointClip()
  throwsCode("ANIM_BINDING_NO_MAPPED_TARGETS", function()
    return AnimationBinding.new(clip, "model:1", {})
  end)
end

function T.binding_unknown_map_target_raises()
  local clip = jointClip()
  throwsCode("ANIM_BINDING_UNKNOWN_TARGET", function()
    return AnimationBinding.new(clip, "model:1", { [99] = 3 })
  end)
end

-- ---- AnimationAttachment ----

function T.attachment_defaults_and_overrides()
  local clip = jointClip()
  local binding = AnimationBinding.new(clip, "model:1", { [3] = 3 })
  local a = AnimationAttachment.new(clip, binding)
  Assert.equal(a.priority, 0x7F)
  Assert.equal(a.ratioFx, 0x1000)
  Assert.isFalse(a.player.paused)
  Assert.equal(a.player.frameCount, 8)

  local opts = { priority = 0x10, ratioFx = 0x800,
    player = AnimationPlayer.new(clip) }
  local b = AnimationAttachment.new(clip, binding, opts)
  Assert.equal(b.priority, 0x10)
  Assert.equal(b.ratioFx, 0x800)
  Assert.equal(b.player, opts.player, "the supplied player is kept")
end

function T.attachment_clip_mismatch_raises()
  local clipA = jointClip()
  local clipB = materialClip()
  local binding = AnimationBinding.new(clipA, "model:1", { [3] = 3 })
  throwsCode("ANIM_ATTACHMENT_BINDING_CLIP_MISMATCH", function()
    return AnimationAttachment.new(clipB, binding)
  end)
end

function T.attachment_bad_priority_or_ratio_raises()
  local clip = jointClip()
  local binding = AnimationBinding.new(clip, "model:1", { [3] = 3 })
  throwsCode("ANIM_ATTACHMENT_BAD_PRIORITY", function()
    return AnimationAttachment.new(clip, binding, { priority = 0x100 })
  end)
  throwsCode("ANIM_ATTACHMENT_BAD_RATIO", function()
    return AnimationAttachment.new(clip, binding, { ratioFx = 0.5 })
  end)
end

-- ---- ModelAnimationState ----

function T.state_attaches_into_category_groups()
  local state = ModelAnimationState.new("model:1")
  local jclip, mclip = jointClip(), materialClip()
  local jtoken = state:attach(jclip, AnimationBinding.new(jclip, "model:1", { [3] = 3 }))
  local mtoken = state:attach(mclip, AnimationBinding.new(mclip, "model:1", { ["door"] = 0 }))
  Assert.equal(#state:attachments("joint"), 1)
  Assert.equal(#state:attachments("material"), 1)
  Assert.equal(#state:attachments("visibility"), 0)
  Assert.equal(state:attachments("joint")[1].clip, jclip)
  state:detach(jtoken)
  Assert.equal(#state:attachments("joint"), 0)
  Assert.equal(#state:attachments("material"), 1, "detach only removes its group")
  state:detach(mtoken)
  Assert.isFalse(state:hasAttachments())
end

function T.state_rejects_foreign_binding()
  local state = ModelAnimationState.new("model:1")
  local clip = jointClip()
  local binding = AnimationBinding.new(clip, "model:2", { [3] = 3 })
  throwsCode("ANIM_STATE_MODEL_MISMATCH", function()
    return state:attach(clip, binding)
  end)
end

function T.state_updates_all_players()
  local state = ModelAnimationState.new("model:1")
  local clip = jointClip()
  local a = state:attach(clip, AnimationBinding.new(clip, "model:1", { [3] = 3 }))
  local b = state:attach(clip, AnimationBinding.new(clip, "model:1", { [3] = 3 }))
  local playerB = state:attachments("joint")[2].player
  playerB:setDirection(-1)
  state:updateFixed()
  local joint = state:attachments("joint")
  Assert.equal(joint[1].player.frameFx, 0x1000)
  Assert.equal(joint[2].player.frameFx, 7 * 0x1000, "reverse wraps to the last frame")
  state:detach(a)
  state:detach(b)
end

function T.state_supports_multiple_simultaneous_clips()
  local state = ModelAnimationState.new("model:1")
  local clip = jointClip()
  -- Two plays of the same clip: two independent attachments.
  state:attach(clip, AnimationBinding.new(clip, "model:1", { [3] = 3 }))
  state:attach(clip, AnimationBinding.new(clip, "model:1", { [3] = 3 }))
  Assert.equal(#state:attachments("joint"), 2)
end

return T
