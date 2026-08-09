-- ModelInstance: pose evaluation, semantic playback, and production draw
-- items over the engine-native IR. All math here is pure: the render smoke
-- test in model_instance_render_test exercises the actual MapRenderer.

local Assert = require("tests.support.Assert")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local AnimationClip = require("libs.engine.src.AnimationClip")
local GenericModelFixture = require("tests.support.GenericModelFixture")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

local function newInstance(opts)
  local def = GenericModelFixture.doorDefinition()
  return ModelInstance.new(def, opts)
end

local function rendersFor(def)
  local renders = {}
  for _, mesh in ipairs(def.meshes) do
    renders[mesh.id] = { id = mesh.id }
  end
  return renders
end

local function leafRotation(instance)
  local pose = instance.poseState
  return pose.nodeMatrices[1]
end

-- The generic backend's rotation interpolation: per-cell lerp of the two key
-- matrices at t = frame / (frameCount - 1), then the engine's basis-vector
-- orthonormalization. Returns the expected rotation cell [1][1] (row 0, col 0).
local function expectedOpenX(frame, frameCount)
  local t = frame / (frameCount - 1)
  local c = (1 - t) * 1 + t * math.cos(1.5)
  local s = t * math.sin(1.5)
  local len = math.sqrt(c * c + s * s)
  return c / len
end

-- ---- playback and pose ----

function T.play_resolves_semantic_names()
  local instance = newInstance()
  local token = instance:play("door.open")
  Assert.notNil(token)
  Assert.equal(#instance.animationState:attachments("joint"), 1)
  throwsCode("ANIM_INSTANCE_UNKNOWN_ANIMATION", function()
    return instance:play("no.such.clip")
  end)
end

function T.bind_pose_is_the_static_hierarchy()
  local instance = newInstance()
  instance:evaluatePose()
  local pose = instance.poseState
  -- Node 2 sits at (4, 0, 0) under the identity root.
  Assert.near(pose.nodeMatrices[2][13], 4, 1e-9)
  Assert.near(pose.nodeMatrices[3][13], 4, 1e-9)
  Assert.isNil(pose.nodeVisible[1], "no visibility clip: nodes stay visible")
end

function T.rigid_node_animation_moves_the_leaf()
  local instance = newInstance()
  instance:play("door.open")
  instance:updateFixed() -- frame 1
  instance:evaluatePose()

  local m = leafRotation(instance)
  local x, _, z = Matrix4.transformPoint(m, 1, 0, 0)
  Assert.near(x, expectedOpenX(1, 8), 1e-9)
  Assert.near(z, -math.sqrt(1 - x * x), 1e-9)
end

function T.two_instances_animate_independently()
  local a, b = newInstance(), newInstance()
  a:play("door.open")
  b:play("door.open")
  b.animationState:attachments("joint")[1].player:setDirection(-1)
  for _ = 1, 3 do
    a:updateFixed()
    b:updateFixed()
  end
  a:evaluatePose()
  b:evaluatePose()
  local ma, mb = leafRotation(a), leafRotation(b)
  -- a at frame 3 (opening), b at frame 5 going backward (also opening);
  -- their rotation cells must differ from each other and from the bind pose.
  Assert.near(ma[1], expectedOpenX(3, 8), 1e-9)
  Assert.near(mb[1], expectedOpenX(5, 8), 1e-9)
  Assert.isFalse(ma[1] == mb[1])
end

function T.multiple_simultaneous_clips()
  local instance = newInstance()
  instance:play("door.open")
  instance:play("door.close")
  Assert.equal(#instance.animationState:attachments("joint"), 2)
  local stopped = instance:stop("door.close")
  Assert.equal(stopped, 1)
  Assert.equal(#instance.animationState:attachments("joint"), 1)
end

function T.stop_by_token()
  local instance = newInstance()
  local token = instance:play("door.open")
  Assert.equal(instance:stop(token), 1)
  Assert.equal(#instance.animationState:attachments("joint"), 0)
end

function T.play_validates_loop_options()
  local instance = newInstance()
  local ok = pcall(instance.play, instance, "door.open", { loopMode = "bounce" })
  Assert.isFalse(ok, "unknown loop mode is a programming error")
  ok = pcall(instance.play, instance, "door.open", { repeatsRemaining = 0 })
  Assert.isFalse(ok, "zero repeats is a programming error")
  ok = pcall(instance.play, instance, "door.open", { direction = 2 })
  Assert.isFalse(ok, "direction must be +-1")
  Assert.equal(#instance.animationState:attachments("joint"), 0,
    "failed plays attach nothing")
end

-- Concurrent clips on one node blend by attachment ratio. At frame 0 the
-- open clip is rotY(0) and the close clip is rotY(1.5); a 50/50 cell blend
-- with the basis-vector rebuild lands exactly on rotY(0.75) (the half-angle
-- identity: atan2(sin x, 1 + cos x) = x / 2).
function T.concurrent_clips_blend_on_the_same_node()
  local instance = newInstance()
  instance:play("door.open")
  instance:play("door.close")
  instance:evaluatePose()
  Assert.near(leafRotation(instance)[1], math.cos(0.75), 1e-9)
  Assert.isFalse(leafRotation(instance)[1] == 1, "the blend differs from either clip alone")

  -- Unequal ratios pull the blend toward the heavier clip.
  local weighted = newInstance()
  weighted:play("door.open", { ratioFx = 0x3000 })
  weighted:play("door.close", { ratioFx = 0x1000 })
  weighted:evaluatePose()
  local w = 0x3000 / (0x3000 + 0x1000)
  local angle = math.atan2((1 - w) * math.sin(1.5), w + (1 - w) * math.cos(1.5))
  Assert.near(leafRotation(weighted)[1], math.cos(angle), 1e-9)
end

-- ---- visibility ----

function T.visibility_clip_hides_the_leaf()
  local instance = newInstance()
  instance:play("blink")
  local renders = rendersFor(instance.definition)
  instance:evaluatePose()
  Assert.isNil(instance.poseState.nodeVisible[1], "frame 0: visible")

  instance:updateFixed()
  instance:updateFixed() -- frame 2: hidden
  instance:evaluatePose()
  Assert.equal(instance.poseState.nodeVisible[1], false)

  local items = instance:drawItems(renders)
  local ids = {}
  for _, item in ipairs(items) do ids[#ids + 1] = item.mesh.id end
  Assert.equal(#ids, 2, "leaf mesh omitted while hidden")
  Assert.isTrue(ids[1] == "frame" and ids[2] == "skin")
end

-- ---- draw items ----

function T.draw_items_carry_pose_transforms()
  local instance = newInstance()
  instance:play("door.open")
  instance:updateFixed()
  instance:evaluatePose()
  local items = instance:drawItems(rendersFor(instance.definition))
  Assert.equal(#items, 3)

  local byId = {}
  for _, item in ipairs(items) do byId[item.mesh.id] = item end
  -- The leaf's transform is the animated rotation; the frame's is identity.
  Assert.near(byId.leaf.transform[1], expectedOpenX(1, 8), 1e-9)
  Assert.near(byId.frame.transform[1], 1, 1e-9)
end

function T.draw_items_compose_the_instance_transform()
  local instance = newInstance({
    transform = Matrix4.translate(10, 0, 20),
  })
  instance:evaluatePose()
  local items = instance:drawItems(rendersFor(instance.definition))
  local frame = nil
  for _, item in ipairs(items) do
    if item.mesh.id == "frame" then frame = item end
  end
  Assert.equal(frame.transform[13], 10)
  Assert.equal(frame.transform[15], 20)
  Assert.deepEqual(frame.center, { 10, 0, 20 })
end

function T.material_contract_maps_to_render_state()
  local instance = newInstance()
  local wall = instance:effectiveMaterial(0)
  Assert.equal(wall.alphaClass, "opaque")
  Assert.equal(wall.cullMode, "back")
  Assert.equal(wall.polygonAlpha, 1.0)
  local glass = instance:effectiveMaterial(1)
  Assert.equal(glass.alphaClass, "cutout")
  Assert.equal(glass.cullMode, "none", "doubleSided disables culling")
  Assert.notNil(glass.alphaCutoff)
  -- Instance state overrides never touch the definition.
  instance.materialState[0].alpha = 128
  Assert.equal(instance:effectiveMaterial(1).polygonAlpha, 1.0,
    "other materials keep their state")
  Assert.near(instance:effectiveMaterial(0).polygonAlpha, 128 / 255, 1e-9)
  Assert.equal(instance.definition.materials[1].baseColor.a, 255)
end

-- ---- skins ----

function T.skin_palette_is_world_times_inverse_bind()
  local instance = newInstance()
  instance:evaluatePose()
  local palette = instance.poseState.jointPalettes["skin"]
  -- Joint 2's world is T(4,0,0) and its inverse bind is T(-4,0,0):
  -- the palette matrix is identity.
  for i = 1, 16 do Assert.near(palette[2][i], Matrix4.identity()[i], 1e-9) end
  -- Joint 3 inherits node 2's placement; the same cancellation applies.
  for i = 1, 16 do Assert.near(palette[3][i], Matrix4.identity()[i], 1e-9) end
end

-- ---- nitro backend contract ----

local function nitroDefinition()
  local def = GenericModelFixture.doorDefinition()
  return ModelDefinition.new({
    key = "vanilla:door",
    sourceBackend = "nitro",
    nodes = def.nodes,
    meshes = def.meshes,
    materials = def.materials,
    skins = def.skins,
    animations = def.animations,
    backend = { opaque = true },
  })
end

function T.nitro_backend_is_pending_until_epic5()
  local def = nitroDefinition()
  local instance = ModelInstance.new(def)
  Assert.isNil(instance:evaluatePose(), "no attachments: nothing to evaluate")

  instance:play("door.open")
  throwsCode("POSE_NITRO_BACKEND_PENDING", function()
    return instance:evaluatePose()
  end)
  -- Without a pose the draw path falls back to bind placement rather than
  -- pretending to animate.
  local items = instance:drawItems(rendersFor(def))
  Assert.equal(#items, 3)
  Assert.equal(items[1].transform[1], 1)
end

function T.backend_source_mismatch_raises()
  local def = nitroDefinition()
  local instance = ModelInstance.new(def)
  local GenericPoseBackend = require("libs.engine.src.GenericPoseBackend")
  throwsCode("POSE_BACKEND_SOURCE_MISMATCH", function()
    return GenericPoseBackend.evaluate(instance)
  end)
end

return T
