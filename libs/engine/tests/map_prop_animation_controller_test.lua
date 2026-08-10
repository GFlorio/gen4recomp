-- MapPropAnimationController tests: the field-facing playback facade
-- (semantic roles, one controller identity per resolved clip, HGSS
-- completion semantics) over a nitro-backed instance.

local Assert = require("tests.support.Assert")
local ModelInstance = require("libs.engine.src.ModelInstance")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")
local NitroModelFixture = require("tests.support.NitroModelFixture")

local T = {}

local function throwsCode(code, fn)
  local ok, result = pcall(fn)
  if ok then
    error("expected a structured " .. code .. " error, got a result")
  end
  Assert.equal(result.code, code)
end

function T.play_resolves_semantic_roles()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  local token = controller:play(instance, "door.open")
  Assert.notNil(token)
  local list = controller:animationsFor(instance)
  Assert.equal(#list, 1)
  Assert.equal(list[1].name, "DoorOpen")
  Assert.deepEqual(list[1].roles, { "door.open" })
end

function T.completion_follows_hgss_frame_advance_and_check()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  controller:play(instance, "door.open")
  -- Forward: finished only when the frame reaches the last frame.
  for _ = 1, 7 do
    Assert.equal(controller:isFinished(instance, "door.open"), false)
    instance:updateFixed()
  end
  Assert.equal(controller:isFinished(instance, "door.open"), true)
  -- Reverse: finished only at the first frame.
  controller:setDirection(instance, "door.open", -1)
  for _ = 1, 6 do
    instance:updateFixed()
    Assert.equal(controller:isFinished(instance, "door.open"), false)
  end
  instance:updateFixed()
  Assert.equal(controller:isFinished(instance, "door.open"), true)
end

function T.stop_pause_resume_and_direction()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  controller:play(instance, "door.open")
  controller:pause(instance, "door.open")
  instance:updateFixed()
  controller:resume(instance, "door.open")
  instance:updateFixed()
  local list = controller:animationsFor(instance)
  Assert.equal(list[1].frame, 1)
  controller:setDirection(instance, "door.open", -1)
  instance:updateFixed()
  Assert.equal(instance.animationState.groups.joint[1].player.frameFx, 0)
  controller:stop(instance, "door.open")
  Assert.equal(#controller:animationsFor(instance), 0)
end

-- Playing the same clip by role and by clip name is ONE controller identity:
-- the token map is keyed by the resolved clip name, so an alias play never
-- leaves an older unreachable attachment behind.
function T.aliases_resolve_to_one_controller_identity()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  local token = controller:play(instance, "door.open")
  controller:play(instance, "DoorOpen")
  local attachmentCount = 0
  for _, category in ipairs({ "joint", "material", "visibility" }) do
    for _ in pairs(instance.animationState.groups[category]) do
      attachmentCount = attachmentCount + 1
    end
  end
  Assert.equal(attachmentCount, 1, "replaying the same clip by alias attaches once")
  local list = controller:animationsFor(instance)
  Assert.equal(#list, 1)
  Assert.equal(list[1].name, "DoorOpen")
  controller:stop(instance, "door.open")
  Assert.equal(#controller:animationsFor(instance), 0, "the alias identity stops with the role")
  -- The first token is no longer valid: its attachment was replaced.
  Assert.isNil(instance.animationState.groups.joint[token])
end

-- Replaying a clip stops the previous attachment first, so the controller's
-- view stays one play per clip.
function T.replay_replaces_the_previous_attachment()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  controller:play(instance, "door.open")
  instance:updateFixed()
  instance:updateFixed()
  controller:play(instance, "door.open")
  local attachments = instance.animationState:attachments("joint")
  Assert.equal(#attachments, 1)
  Assert.equal(attachments[1].player.frameFx, 0, "the replay restarts the clip")
end

function T.unknown_animation_raises()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  throwsCode("MAP_PROP_ANIM_UNKNOWN", function()
    controller:play(instance, "door.slide")
  end)
end

function T.on_mutation_fires_on_control_ops()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  local mutations = 0
  controller.onMutation = function()
    mutations = mutations + 1
  end
  controller:play(instance, "door.open")
  controller:pause(instance, "door.open")
  controller:resume(instance, "door.open")
  controller:setDirection(instance, "door.open", -1)
  controller:stop(instance, "door.open")
  Assert.equal(mutations, 5, "every control op marks the scene's draw list dirty")
end

return T
