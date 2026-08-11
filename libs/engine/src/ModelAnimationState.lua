-- ModelAnimationState: the per-instance collection of playing attachments,
-- kept in the same three attachment groups NitroSystem uses because the
-- groups do not combine state identically:
--
--   joint        -- NSBCA-style node transforms (blended)
--   material     -- NSBTA/NSBTP/NSBMA material state (composed)
--   visibility   -- NSBVA node visibility (selection)
--
-- Attachments are attached by clip category into the matching group and are
-- independent of each other: any number of clips of any group can play
-- simultaneously on one model. The binding comes from the definition (the
-- definition IS the model), so attach takes the clip and playback opts only
-- -- never a caller-supplied binding. Each attach returns the
-- LIVE attachment as the handle; detach(handle) removes exactly that
-- attachment. Storage is compact: each group is an array of the active
-- attachments in attach order, so attachments(category) snapshots only what
-- is active and detach never scans the other groups -- there is
-- no token bookkeeping and no monotonically growing range. The group
-- evaluators (pose backends, material evaluator) read attachments() at
-- evaluation time; attachment order IS significant to the material
-- evaluator's equal-priority tie (last attached wins), so the snapshot keeps
-- attach order.
--
-- Two instances of one model each own a state, so the same clip can play at
-- different frames on different instances. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local AnimationClip = require("libs.engine.src.AnimationClip")
local AnimationPlayer = require("libs.engine.src.AnimationPlayer")

local ModelAnimationState = {}
ModelAnimationState.__index = ModelAnimationState

ModelAnimationState.GROUPS = { "joint", "material", "visibility" }

ModelAnimationState.DEFAULT_PRIORITY = 0x7F
ModelAnimationState.DEFAULT_RATIO_FX = 0x1000

function ModelAnimationState.new(definition)
  assert(type(definition) == "table" and definition.key ~= nil, "ModelAnimationState.new requires a ModelDefinition")
  return setmetatable({
    definition = definition,
    groups = { joint = {}, material = {}, visibility = {} },
  }, ModelAnimationState)
end

-- Attach a clip to the group its category selects, bound through the
-- definition's precomputed binding. `opts` may supply the player (defaults
-- to a fresh one), priority (0..0xFF), and ratioFx (any integer; combination
-- evaluates the sign). A clip whose binding resolves zero model elements is
-- a data failure and raises ANIM_STATE_ZERO_BINDING. Returns the LIVE
-- attachment as the handle.
function ModelAnimationState:attach(clip, opts)
  if not AnimationClip.CATEGORIES[clip.category] then
    Errors.raise(
      "ANIM_STATE_BAD_CATEGORY",
      "clip " .. clip.id .. " has unknown category " .. tostring(clip.category),
      {}
    )
  end
  local binding = self.definition:binding(clip)
  if next(binding.map) == nil then
    Errors.raise(
      "ANIM_STATE_ZERO_BINDING",
      "clip "
        .. clip.id
        .. " binds zero model elements of "
        .. self.definition.key
        .. "; the animation/model association is likely wrong",
      { clip = clip.id, modelKey = self.definition.key }
    )
  end

  opts = opts or {}
  local priority = opts.priority or ModelAnimationState.DEFAULT_PRIORITY
  local ratioFx = opts.ratioFx or ModelAnimationState.DEFAULT_RATIO_FX
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

  local attachment = {
    clip = clip,
    binding = binding,
    player = opts.player or AnimationPlayer.new(clip),
    priority = priority,
    ratioFx = ratioFx,
  }
  local group = self.groups[clip.category]
  group[#group + 1] = attachment
  return attachment
end

-- Detach exactly the given attachment, returning the number of attachments
-- removed (1 or 0). A handle that is not attached is a no-op (a double stop
-- removes nothing).
function ModelAnimationState:detach(handle)
  if type(handle) ~= "table" or not handle.clip then
    return 0
  end
  local group = self.groups[handle.clip.category]
  for i, attachment in ipairs(group) do
    if attachment == handle then
      table.remove(group, i)
      return 1
    end
  end
  return 0
end

-- A snapshot list of the active attachments in one group, in attach order
-- (the storage is already compact: only the active attachments live in the
-- array, so the snapshot is O(active), not O(ever-attached)).
function ModelAnimationState:attachments(category)
  local out = {}
  local group = self.groups[category]
  for _, attachment in ipairs(group) do
    out[#out + 1] = attachment
  end
  return out
end

-- Advance every player of every group by one fixed step.
function ModelAnimationState:updateFixed()
  for _, group in pairs(self.groups) do
    for _, attachment in ipairs(group) do
      attachment.player:updateFixed()
    end
  end
end

-- True when any attachment is playing in a group (or any group when `category`
-- is omitted).
function ModelAnimationState:hasAttachments(category)
  if category then
    return next(self.groups[category]) ~= nil
  end
  for _, group in pairs(self.groups) do
    if next(group) ~= nil then
      return true
    end
  end
  return false
end

return ModelAnimationState
