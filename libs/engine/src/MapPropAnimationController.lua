-- MapPropAnimationController: the field-specific controller above the
-- generic animation runtime (spec section 37). It owns the semantic
-- animation roles of a scene's animated map props -- gameplay addresses
-- animations by role ("door.open") or clip name, never by Nitro resource
-- numbers -- and provides the playback operations the field systems use
-- (door choreography, ambient props). The role resolution itself lives in
-- ModelDefinition (clips carry semanticNames); this controller adds the
-- per-instance playback bookkeeping and the HGSS completion semantics.
--
-- Completion (ov01_021FBEE4 Field3dModelAnimation_FrameAdvanceAndCheck,
-- pokeheartgold overlay_01_021FB878.s): a forward clip is finished when its
-- frame reaches the last frame, a reverse clip when it reaches the first.
--
-- Pure domain module.

local Errors = require("libs.rom.src.Errors")

local MapPropAnimationController = {}
MapPropAnimationController.__index = MapPropAnimationController

function MapPropAnimationController.new()
  return setmetatable({
    -- instance -> { [animationName] = token } -- the controller's own plays
    tokens = {},
  }, MapPropAnimationController)
end

-- The animation identifier an op resolves: a semantic role or a clip name.
local function resolveName(definition, animation)
  local clip = definition:animation(animation)
  if not clip then
    Errors.raise(
      "MAP_PROP_ANIM_UNKNOWN",
      "map prop has no animation named " .. tostring(animation) .. " (model " .. definition.key .. ")",
      { animation = animation, modelKey = definition.key }
    )
  end
  return clip.name
end

local function instanceTokens(self, instance)
  local byName = self.tokens[instance]
  if not byName then
    byName = {}
    self.tokens[instance] = byName
  end
  return byName
end

-- The animation list of an instance: every playing clip with its role,
-- frame, and playback state (the debugger's instance view).
function MapPropAnimationController:animationsFor(instance)
  local out = {}
  local definition = instance.definition
  for _, clip in ipairs(definition.animations) do
    local roles = clip.semanticNames
    for _, category in ipairs({ "joint", "material", "visibility" }) do
      for _, attachment in ipairs(instance.animationState:attachments(category)) do
        if attachment.clip == clip then
          out[#out + 1] = {
            name = clip.name,
            roles = roles,
            frame = attachment.player.frameFx / 4096,
            frameCount = clip.frameCount,
            playing = not attachment.player.paused and not attachment.player.completed,
          }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

-- Play an animation by role or clip name. `opts` passes through to
-- instance:play (priority, ratioFx, loopMode, repeatsRemaining, deltaFx,
-- direction). Returns the attachment token.
function MapPropAnimationController:play(instance, animation, opts)
  local name = resolveName(instance.definition, animation)
  local token = instance:play(name, opts)
  instanceTokens(self, instance)[animation] = token
  return token
end

function MapPropAnimationController:stop(instance, animation)
  local name = resolveName(instance.definition, animation)
  local removed = instance:stop(name)
  local tokens = instanceTokens(self, instance)
  tokens[animation] = nil
  for key, token in pairs(tokens) do
    if instance.definition:animation(key) and instance.definition:animation(key).name == name then
      tokens[key] = nil
    end
  end
  return removed
end

-- The controller's own attachment for `animation` on `instance`, or nil.
local function attachmentFor(self, instance, animation)
  local tokens = self.tokens[instance]
  local token = tokens and tokens[animation]
  if token == nil then
    return nil
  end
  for _, category in ipairs({ "joint", "material", "visibility" }) do
    local attachment = instance.animationState.groups[category][token]
    if attachment then
      return attachment
    end
  end
  return nil
end

function MapPropAnimationController:pause(instance, animation)
  local attachment = attachmentFor(self, instance, animation)
  if attachment then
    attachment.player:pause()
  end
end

function MapPropAnimationController:resume(instance, animation)
  local attachment = attachmentFor(self, instance, animation)
  if attachment then
    attachment.player:play()
  end
end

function MapPropAnimationController:setDirection(instance, animation, direction)
  local attachment = attachmentFor(self, instance, animation)
  if attachment then
    attachment.player:setDirection(direction)
  end
end

-- The HGSS completion check: a forward clip finishes when its frame reaches
-- the last frame, a reverse clip when it reaches the first (the checked
-- advance clamps there and reports completion; the field managers read the
-- same condition before a door sequence proceeds). Nil when the controller
-- has no play of the animation.
function MapPropAnimationController:isFinished(instance, animation)
  local attachment = attachmentFor(self, instance, animation)
  if not attachment then
    return nil
  end
  local player = attachment.player
  if player.deltaFx >= 0 then
    return player.frameFx >= (player.frameCount - 1) * 4096
  end
  return player.frameFx <= 0
end

return MapPropAnimationController
