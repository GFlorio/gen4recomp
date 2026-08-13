-- ModelInstance playback-surface tests: the collapsed animation object
-- graph. instance:play resolves the clip by name or
-- semantic role, attaches it through the state's precomputed definition
-- binding, and returns the LIVE attachment as the handle -- a plain table
-- carrying clip/binding/player. A second play of a clip whose kind already
-- plays raises ANIM_STATE_SAME_KIND_IN_USE (one attachment per kind).
-- stop() takes the handle (or a name/semantic, removing every play of that
-- clip). The HGSS completion condition reads the retained handle's player
-- terminal state. There is no controller layer: no
-- pause/resume/setDirection/animationsFor facade exists without a game
-- caller.

local Assert = require("tests.support.Assert")
local ModelInstance = require("libs.engine.src.ModelInstance")
local NitroModelFixture = require("tests.support.NitroModelFixture")
local AnimationClip = require("libs.assets.src.AnimationClip")

local T = {}

local function throwsCode(code, fn)
  local ok, result = pcall(fn)
  if ok then
    error("expected a structured " .. code .. " error, got a result")
  end
  Assert.equal(result.code, code)
end

function T.play_returns_the_live_attachment_handle()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  local handle = instance:play("door.open")
  Assert.equal(type(handle), "table", "play returns the attachment handle, not a token")
  Assert.equal(handle.clip.name, "DoorOpen")
  Assert.deepEqual(handle.clip.semanticNames, { "door.open" })
  Assert.notNil(handle.player)
end

-- The handle returned by play IS the attachment the state enumerates: the
-- caller's handle is the live record, not a separate bookkeeping object.
function T.the_play_handle_is_the_attachment_the_state_enumerates()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  local handle = instance:play("door.open")
  Assert.isTrue(instance.animationState:attachments("joint")[1] == handle)
end

-- The single completion notion: a once-clip finishes exactly when the
-- retained handle's player reaches numFrame * FRAME_UNIT -- the checked
-- advance's positive terminal (numFrame << 12) -- never at the last key
-- frame one tick earlier.
function T.completion_follows_the_checked_advance_terminal()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  local handle = instance:play("door.open", { loopMode = "once" })
  for _ = 1, 7 do
    Assert.equal(handle.player:isComplete(), false)
    instance:updateFixed()
  end
  Assert.equal(handle.player:isComplete(), false, "the checked advance is not done at the last key frame")
  instance:updateFixed()
  Assert.equal(handle.player.frameFx, 8 * 0x1000, "the terminal is exactly numFrame * FRAME_UNIT")
  Assert.equal(handle.player:isComplete(), true, "the once clip reports done at the checked-advance terminal")
end

function T.stop_by_handle_detaches_the_attachment()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  local handle = instance:play("door.open")
  Assert.equal(instance:stop(handle), 1)
  Assert.equal(#instance.animationState:attachments("joint"), 0)
end

-- Replaying a clip whose kind is already playing is rejected: one
-- attachment per kind, so a second play raises instead of stacking
-- (MapDoor stops the previous play first, so replays restart fresh).
function T.replaying_an_attached_kind_raises()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  instance:play("door.open")
  throwsCode("ANIM_STATE_SAME_KIND_IN_USE", function()
    return instance:play("DoorOpen")
  end)
  Assert.equal(#instance.animationState:attachments("joint"), 1, "the rejected play attaches nothing")
end

function T.unknown_animation_raises()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  throwsCode("ANIM_INSTANCE_UNKNOWN_ANIMATION", function()
    return instance:play("no.such.clip")
  end)
end

-- A clip whose tracks bind no model element is a data failure at play time:
-- the precomputed binding is zero-mapped and playback must fail loudly,
-- never attach a silent no-op.
function T.play_of_a_zero_binding_clip_fails_loudly()
  local ghost = AnimationClip.new({
    id = "fixture:ghost",
    name = "ghost",
    category = "material",
    kind = "color",
    frameCount = 4,
    compiled = {},
    tracks = {
      {
        target = "absent",
        channels = { diffuse = { interpolation = "step", keys = { { frame = 0, value = 0x203C } } } },
      },
    },
  })
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition({ ghost }))
  throwsCode("ANIM_STATE_ZERO_BINDING", function()
    return instance:play("ghost")
  end)
  Assert.equal(#instance.animationState:attachments("material"), 0, "the failed play attaches nothing")
end

-- The O(active) surface contract: play/stop cycles through the
-- returned handle leave the state enumerating only the active attachments --
-- no growing token range to scan.
function T.play_stop_cycles_leave_no_stale_attachments()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  for _ = 1, 100 do
    local handle = instance:play("door.open")
    instance:stop(handle)
  end
  Assert.equal(#instance.animationState:attachments("joint"), 0)
  local survivor = instance:play("door.open")
  Assert.equal(#instance.animationState:attachments("joint"), 1)
  Assert.isTrue(instance.animationState:attachments("joint")[1] == survivor)
end

return T
