-- MapPropAnimationController + AnimationDebugger tests: the field-facing
-- playback facade (semantic roles, HGSS completion semantics) and the
-- inspector snapshot/controls over a nitro-backed instance.

local Assert = require("tests.support.Assert")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")
local AnimationDebugger = require("libs.engine.src.AnimationDebugger")

local T = {}

local function throwsCode(code, fn)
  local ok, result = pcall(fn)
  if ok then
    error("expected a structured " .. code .. " error, got a result")
  end
  Assert.equal(result.code, code)
end

-- A nitro door definition: joint clips door_op/door_cl with semantic roles
-- (the compiled shape NsbcaClipCompiler emits) and a material clip.
local function doorDefinition()
  local function doorClip(name, role)
    return {
      id = "fixture:" .. name,
      name = name,
      category = "joint",
      kind = "trs",
      frameCount = 8,
      tracks = { { target = 0, targetIndex = 0 } },
      semanticNames = { role },
      source = { type = "nitro", format = "NSBCA", archive = "build_anim", memberId = 1 },
      compiled = { anmFlags = 0, rotData = {}, pivotData = {}, targets = { { nodeIndex = 0, channels = {} } } },
    }
  end
  local identity = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
  return ModelDefinition.new({
    key = "fixture:door",
    sourceBackend = "nitro",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity,
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = { { id = "door", nodeIndex = 0, materialIndex = 0, batch = { vertices = {}, indices = {} } } },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
      },
    },
    skins = {},
    animations = { doorClip("door_op", "door.open"), doorClip("door_cl", "door.close") },
    backend = { program = { name = "door", nodes = { { index = 0 } } }, meshes = {} },
  })
end

-- ---- controller ----

function T.play_resolves_semantic_roles()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(doorDefinition())
  local token = controller:play(instance, "door.open")
  Assert.notNil(token)
  local list = controller:animationsFor(instance)
  Assert.equal(#list, 1)
  Assert.equal(list[1].name, "door_op")
  Assert.deepEqual(list[1].roles, { "door.open" })
end

function T.completion_follows_hgss_frame_advance_and_check()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(doorDefinition())
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
  local instance = ModelInstance.new(doorDefinition())
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

function T.unknown_animation_raises()
  local controller = MapPropAnimationController.new()
  local instance = ModelInstance.new(doorDefinition())
  throwsCode("MAP_PROP_ANIM_UNKNOWN", function()
    controller:play(instance, "door.slide")
  end)
end

-- ---- debugger ----

function T.snapshot_reports_attachment_fields()
  local instance = ModelInstance.new(doorDefinition())
  instance:play("door.close", { priority = 0x40, ratioFx = 0x800 })
  instance:updateFixed()
  local entries = AnimationDebugger.snapshot(instance)
  Assert.equal(#entries, 1)
  local e = entries[1]
  Assert.equal(e.model, "fixture:door")
  Assert.equal(e.clipName, "door_cl")
  Assert.equal(e.role, nil)
  Assert.equal(e.slot, 1)
  Assert.equal(e.category, "joint")
  Assert.equal(e.format, "NSBCA")
  Assert.equal(e.memberId, 1)
  Assert.equal(e.frame, 1)
  Assert.equal(e.frameCount, 8)
  Assert.equal(e.priority, 0x40)
  Assert.equal(e.ratioFx, 0x800)
  Assert.equal(e.boundTargets, 1)
end

function T.snapshot_controls_scrub_and_loop()
  local instance = ModelInstance.new(doorDefinition())
  instance:play("door.open")
  local entries = AnimationDebugger.snapshot(instance)
  local e = entries[1]
  Assert.isTrue(AnimationDebugger.pause(instance, e))
  instance:updateFixed()
  entries = AnimationDebugger.snapshot(instance)
  Assert.equal(entries[1].frame, 0)
  Assert.isTrue(AnimationDebugger.play(instance, entries[1]))
  instance:updateFixed()
  entries = AnimationDebugger.snapshot(instance)
  Assert.equal(entries[1].frame, 1)
  Assert.isTrue(AnimationDebugger.seekFx(instance, entries[1], 5 * 4096))
  entries = AnimationDebugger.snapshot(instance)
  Assert.equal(entries[1].frame, 5)
  Assert.isTrue(AnimationDebugger.setDirection(instance, entries[1], -1))
  entries = AnimationDebugger.snapshot(instance)
  Assert.equal(entries[1].direction, "reverse")
  Assert.isTrue(AnimationDebugger.setDeltaFx(instance, entries[1], 0x800))
  entries = AnimationDebugger.snapshot(instance)
  Assert.equal(entries[1].deltaFx, 0x800)
  Assert.isTrue(AnimationDebugger.setLoopMode(instance, entries[1], "once"))
  entries = AnimationDebugger.snapshot(instance)
  Assert.equal(entries[1].loopMode, "once")
end

return T
