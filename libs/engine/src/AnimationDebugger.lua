-- AnimationDebugger: the inspector for the animation runtime (spec section
-- 37). It snapshots every attachment of an instance -- the fields the
-- debugger UI needs (instance, model, source member, animation slot, source
-- format, clip name, frame, frame count, play/pause, forward/reverse, loop,
-- speed, bound targets, attachment priority and ratio) -- and exposes the
-- scrub controls (seek, direction, speed, loop) over a snapshot entry.
-- Pure domain module; the overlay UI that renders the snapshots is a
-- presentation concern (Epic 10).

local AnimationDebugger = {}

local FRAME_UNIT = 4096

-- One attachment entry. `slot` is the clip's index in the definition's
-- animation list (the source-format slot the field managers address).
local function entryFor(instance, clip, slot, category, attachment)
  local player = attachment.player
  local source = clip.source or {}
  return {
    instance = instance,
    model = instance.definition.key,
    slot = slot,
    category = category,
    clipName = clip.name,
    roles = clip.semanticNames,
    format = source.format or "generic",
    memberId = source.memberId,
    frame = player.frameFx / FRAME_UNIT,
    frameCount = player.frameCount,
    playing = not player.paused and not player.completed,
    paused = player.paused,
    completed = player.completed,
    direction = player.deltaFx < 0 and "reverse" or "forward",
    deltaFx = player.deltaFx,
    loopMode = player.loopMode,
    repeatsRemaining = player.repeatsRemaining,
    priority = attachment.priority,
    ratioFx = attachment.ratioFx,
    boundTargets = attachment.binding:mappedTargetCount(),
  }
end

-- Snapshot every attachment of `instance` (or one category), in attach
-- order. Entries carry the clip slot; controls operate on the
-- (instance, clipName) tuple.
function AnimationDebugger.snapshot(instance, category)
  assert(
    type(instance) == "table" and instance.definition ~= nil,
    "AnimationDebugger.snapshot requires a ModelInstance"
  )
  local out = {}
  local categories = category and { category } or { "joint", "material", "visibility" }
  local slotOf = {}
  for slot, clip in ipairs(instance.definition.animations) do
    slotOf[clip] = slot - 1
  end
  for _, clip in ipairs(instance.definition.animations) do
    for _, cat in ipairs(categories) do
      for _, attachment in ipairs(instance.animationState:attachments(cat)) do
        if attachment.clip == clip then
          out[#out + 1] = entryFor(instance, clip, slotOf[clip], cat, attachment)
        end
      end
    end
  end
  return out
end

-- Controls: operate on the snapshot entry's clip across the instance's
-- attachments (the first playing attachment of that clip in the category).

local function find(instance, entry)
  assert(entry and entry.instance == instance, "snapshot entry belongs to the instance")
  for _, cat in ipairs({ "joint", "material", "visibility" }) do
    for _, attachment in ipairs(instance.animationState:attachments(cat)) do
      if attachment.clip.name == entry.clipName then
        return attachment
      end
    end
  end
  return nil
end

function AnimationDebugger.play(instance, entry)
  local attachment = find(instance, entry)
  if attachment then
    attachment.player:play()
  end
  return attachment ~= nil
end

function AnimationDebugger.pause(instance, entry)
  local attachment = find(instance, entry)
  if attachment then
    attachment.player:pause()
  end
  return attachment ~= nil
end

function AnimationDebugger.seekFx(instance, entry, frameFx)
  local attachment = find(instance, entry)
  if attachment then
    attachment.player:seekFx(frameFx)
  end
  return attachment ~= nil
end

function AnimationDebugger.setDirection(instance, entry, direction)
  local attachment = find(instance, entry)
  if attachment then
    attachment.player:setDirection(direction)
  end
  return attachment ~= nil
end

function AnimationDebugger.setDeltaFx(instance, entry, deltaFx)
  local attachment = find(instance, entry)
  if attachment then
    attachment.player:setDeltaFx(deltaFx)
  end
  return attachment ~= nil
end

function AnimationDebugger.setLoopMode(instance, entry, loopMode)
  local attachment = find(instance, entry)
  if attachment then
    attachment.player.loopMode = loopMode
  end
  return attachment ~= nil
end

return AnimationDebugger
