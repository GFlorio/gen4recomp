-- AnimationAttachment: one playing clip bound to one model. An attachment
-- ties the immutable definition pieces (clip, binding) to the mutable
-- playback piece (player) and carries the combination policy the evaluators
-- honor:
--
--   attachment = {
--     clip = clip,        -- the normalized animation
--     binding = binding,  -- clip targets mapped onto the model
--     player = player,    -- owned playback state
--     priority = 0x7F,    -- policy field for combination order (see below)
--     ratioFx = 0x1000,   -- combination weight, fixed point
--   }
--
-- The attachment surface is the generic layer: no NARC members, NSBCA
-- structures, or Nitro dictionary entries appear here. The clip category
-- decides which ModelAnimationState group the attachment belongs to.
--
-- priority is exposed because higher layers (e.g. the HGSS field animation
-- manager) arbitrate slots by priority; the Nitro joint blend itself uses
-- ratios only (pokediamond anm.s NNSi_G3dAnmBlendJnt never reads priority).
-- Pure domain module.

local AnimationPlayer = require("libs.engine.src.AnimationPlayer")
local Errors = require("libs.rom.src.Errors")

local AnimationAttachment = {}
AnimationAttachment.__index = AnimationAttachment

AnimationAttachment.DEFAULT_PRIORITY = 0x7F
AnimationAttachment.DEFAULT_RATIO_FX = 0x1000

-- Build an attachment for `clip` over `binding`. `opts` may supply the
-- player (defaults to a fresh one), priority (0..0xFF), and ratioFx
-- (any integer; combination evaluates the sign).
function AnimationAttachment.new(clip, binding, opts)
  assert(type(clip) == "table" and clip.id ~= nil, "AnimationAttachment.new requires a clip")
  assert(type(binding) == "table" and binding.clip ~= nil, "AnimationAttachment.new requires a binding")
  if binding.clip ~= clip then
    Errors.raise(
      "ANIM_ATTACHMENT_BINDING_CLIP_MISMATCH",
      "attachment binding is for clip " .. binding.clip.id .. ", not clip " .. clip.id,
      { clip = clip.id }
    )
  end

  opts = opts or {}
  local priority = opts.priority or AnimationAttachment.DEFAULT_PRIORITY
  local ratioFx = opts.ratioFx or AnimationAttachment.DEFAULT_RATIO_FX
  if not (type(priority) == "number" and math.floor(priority) == priority and priority >= 0 and priority <= 0xFF) then
    Errors.raise(
      "ANIM_ATTACHMENT_BAD_PRIORITY",
      "attachment priority must be an integer in 0..0xFF, got " .. tostring(priority),
      { clip = clip.id }
    )
  end
  if not (type(ratioFx) == "number" and math.floor(ratioFx) == ratioFx) then
    Errors.raise(
      "ANIM_ATTACHMENT_BAD_RATIO",
      "attachment ratioFx must be an integer, got " .. tostring(ratioFx),
      { clip = clip.id }
    )
  end

  return setmetatable({
    clip = clip,
    binding = binding,
    player = opts.player or AnimationPlayer.new(clip),
    priority = priority,
    ratioFx = ratioFx,
  }, AnimationAttachment)
end

return AnimationAttachment
