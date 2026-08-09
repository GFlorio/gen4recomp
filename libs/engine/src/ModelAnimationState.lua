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
-- simultaneously on one model. Each attach returns a token for detach.
-- updateFixed() advances every attachment's player; the group evaluators
-- (pose backends, material evaluator) read attachments() at evaluation time,
-- so attachment order never matters to the math.
--
-- Two instances of one model each own a state, so the same clip can play at
-- different frames on different instances. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local AnimationClip = require("libs.engine.src.AnimationClip")
local AnimationAttachment = require("libs.engine.src.AnimationAttachment")

local ModelAnimationState = {}
ModelAnimationState.__index = ModelAnimationState

ModelAnimationState.GROUPS = { "joint", "material", "visibility" }

function ModelAnimationState.new(modelKey)
  return setmetatable({
    modelKey = modelKey,
    groups = { joint = {}, material = {}, visibility = {} },
    nextToken = 1,
  }, ModelAnimationState)
end

-- Attach a clip over a binding to the group its category selects. Returns a
-- token usable with detach. `opts` passes through to AnimationAttachment.new.
function ModelAnimationState:attach(clip, binding, opts)
  if not AnimationClip.CATEGORIES[clip.category] then
    Errors.raise("ANIM_STATE_BAD_CATEGORY",
      "clip " .. clip.id .. " has unknown category " .. tostring(clip.category), {})
  end
  if binding.modelKey ~= self.modelKey then
    Errors.raise("ANIM_STATE_MODEL_MISMATCH",
      "clip " .. clip.id .. " is bound to model " .. binding.modelKey
        .. " but the state belongs to " .. tostring(self.modelKey),
      { clip = clip.id, bindingModel = binding.modelKey, stateModel = self.modelKey })
  end
  local attachment = AnimationAttachment.new(clip, binding, opts)
  local token = self.nextToken
  self.nextToken = self.nextToken + 1
  local group = self.groups[clip.category]
  group[token] = attachment
  return token
end

function ModelAnimationState:detach(token)
  for _, group in pairs(self.groups) do group[token] = nil end
end

-- A snapshot list of the attachments in one group, in attach order (tokens
-- are sequential, so a numeric walk is deterministic).
function ModelAnimationState:attachments(category)
  local out = {}
  local group = self.groups[category]
  for token = 1, self.nextToken - 1 do
    local attachment = group[token]
    if attachment then out[#out + 1] = attachment end
  end
  return out
end

-- Advance every player of every group by one fixed step.
function ModelAnimationState:updateFixed()
  for _, group in pairs(self.groups) do
    for _, attachment in pairs(group) do attachment.player:updateFixed() end
  end
end

-- True when any attachment is playing in a group (or any group when `category`
-- is omitted).
function ModelAnimationState:hasAttachments(category)
  if category then return next(self.groups[category]) ~= nil end
  for _, group in pairs(self.groups) do
    if next(group) ~= nil then return true end
  end
  return false
end

return ModelAnimationState
