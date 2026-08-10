-- MapPropAnimationController: the field-specific controller above the
-- animation runtime. It owns the semantic animation roles of a scene's
-- animated map props -- gameplay addresses animations by role ("door.open")
-- or clip name, never by Nitro resource numbers -- and provides the playback
-- operations the field systems use (door choreography, ambient props). The
-- role resolution itself lives in ModelDefinition (clips carry
-- semanticNames); this controller adds the per-instance playback
-- bookkeeping and the HGSS completion semantics.
--
-- Controller identity is the resolved clip name: playing the same clip by
-- two aliases (role and name) drives one attachment, and replaying a clip
-- stops the previous attachment first -- an older play of the same clip can
-- never become unreachable. Playback options pass through to
-- ModelInstance:play.
--
-- Completion (ov01_021FBEE4 Field3dModelAnimation_FrameAdvanceAndCheck,
-- pokeheartgold overlay_01_021FB878.s): a forward clip is finished when its
-- frame reaches the last frame, a reverse clip when it reaches the first --
-- the player's checked-advance terminal state, centralized in
-- AnimationPlayer.atTerminal.
--
-- Pure domain module.

local Errors = require("libs.rom.src.Errors")
local AnimationPlayer = require("libs.engine.src.AnimationPlayer")
local ModelAnimationState = require("libs.engine.src.ModelAnimationState")

local MapPropAnimationController = {}
MapPropAnimationController.__index = MapPropAnimationController

-- The semantic door roles gameplay addresses clips by (compiled onto the
-- clips by MapPropAnimCompiler's role patterns).
MapPropAnimationController.ROLES = {
  DOOR_OPEN = "door.open",
  DOOR_CLOSE = "door.close",
}

function MapPropAnimationController.new()
  return setmetatable({
    -- instance -> { [resolvedClipName] = token } -- the controller's own plays
    tokens = {},
    -- Optional callback invoked after every mutating op (play/stop/pause/
    -- resume/setDirection), so the scene loader can mark its animated draw
    -- list dirty when a control op happens outside a fixed tick.
    onMutation = nil,
  }, MapPropAnimationController)
end

local function raiseUnknown(definition, animation)
  Errors.raise(
    "MAP_PROP_ANIM_UNKNOWN",
    "map prop has no animation named " .. tostring(animation) .. " (model " .. definition.key .. ")",
    { animation = animation, modelKey = definition.key }
  )
end

-- The animation identifier an op resolves: a semantic role or a clip name.
local function resolveName(definition, animation)
  local clip = definition:animation(animation)
  if not clip then
    raiseUnknown(definition, animation)
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

-- The controller's own attachment for a resolved clip name on `instance`,
-- or nil.
local function attachmentFor(self, instance, clipName)
  local tokens = self.tokens[instance]
  local token = tokens and tokens[clipName]
  if token == nil then
    return nil
  end
  for _, category in ipairs(ModelAnimationState.GROUPS) do
    local attachment = instance.animationState.groups[category][token]
    if attachment then
      return attachment
    end
  end
  return nil
end

local function markMutation(self)
  if self.onMutation then
    self.onMutation()
  end
end

-- The animation list of an instance: every playing clip with its role,
-- frame, and playback state (the controller's instance view).
function MapPropAnimationController:animationsFor(instance)
  local out = {}
  local definition = instance.definition
  for _, clip in ipairs(definition.animations) do
    local attachment = attachmentFor(self, instance, clip.name)
    if attachment then
      out[#out + 1] = {
        name = clip.name,
        roles = clip.semanticNames,
        frame = attachment.player.frameFx / AnimationPlayer.FRAME_UNIT,
        frameCount = clip.frameCount,
        playing = not attachment.player.paused and not attachment.player.completed,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

-- Play an animation by role or clip name. `opts` passes through to
-- instance:play (priority, ratioFx, loopMode, direction). Replaying a clip
-- that is already playing stops the previous attachment first, so one clip
-- has one controller identity. Returns the attachment token.
function MapPropAnimationController:play(instance, animation, opts)
  local name = resolveName(instance.definition, animation)
  local previous = attachmentFor(self, instance, name)
  if previous then
    instance:stop(name)
  end
  local token = instance:play(name, opts)
  instanceTokens(self, instance)[name] = token
  markMutation(self)
  return token
end

function MapPropAnimationController:stop(instance, animation)
  local name = resolveName(instance.definition, animation)
  local removed = instance:stop(name)
  local tokens = instanceTokens(self, instance)
  if removed > 0 or tokens[name] ~= nil then
    tokens[name] = nil
    markMutation(self)
  end
  return removed
end

function MapPropAnimationController:pause(instance, animation)
  local name = resolveName(instance.definition, animation)
  local attachment = attachmentFor(self, instance, name)
  if attachment then
    attachment.player:pause()
    markMutation(self)
  end
end

function MapPropAnimationController:resume(instance, animation)
  local name = resolveName(instance.definition, animation)
  local attachment = attachmentFor(self, instance, name)
  if attachment then
    attachment.player:play()
    markMutation(self)
  end
end

function MapPropAnimationController:setDirection(instance, animation, direction)
  local name = resolveName(instance.definition, animation)
  local attachment = attachmentFor(self, instance, name)
  if attachment then
    attachment.player:setDirection(direction)
    markMutation(self)
  end
end

-- The HGSS completion check: a forward clip finishes when its frame reaches
-- the last frame, a reverse clip when it reaches the first (the checked
-- advance clamps there and reports completion; the field managers read the
-- same condition before a door sequence proceeds). Nil when the controller
-- has no play of the animation.
function MapPropAnimationController:isFinished(instance, animation)
  local name = resolveName(instance.definition, animation)
  local attachment = attachmentFor(self, instance, name)
  if not attachment then
    return nil
  end
  return attachment.player:atTerminal()
end

return MapPropAnimationController
