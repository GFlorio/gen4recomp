-- ModelInstance: pose evaluation, semantic playback, and production draw
-- items over the nitro runtime. All math here is pure: the render smoke test
-- in model_instance_render_test exercises the actual MapRenderer.

local Assert = require("tests.support.Assert")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local NitroModelFixture = require("tests.support.NitroModelFixture")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

local function newInstance(opts)
  return ModelInstance.new(NitroModelFixture.doorDefinition(), opts)
end

-- A door definition whose material carries a texture, so effectiveMaterial
-- exercises the resolveImage callback (untextured materials never call it).
local function texturedDoorDefinition()
  local def = NitroModelFixture.doorDefinition()
  def.materials[1] = {
    id = 0,
    name = "wall",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    alphaMode = "opaque",
    doubleSided = false,
    texture = "wall.png",
    texWidth = 64,
    texHeight = 64,
  }
  return def
end

local function rendersFor(def)
  local renders = {}
  for _, mesh in ipairs(def.meshes) do
    renders[mesh.id] = { id = mesh.id }
  end
  return renders
end

-- The swing clip's rotation cell [1] (row 0, col 0) of the door draw matrix.
local function swingCell(instance)
  local draw = instance.poseState.drawMatrices["draw0.seg0"]
  return draw.position[1]
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

function T.bind_pose_is_the_identity_draw()
  local instance = newInstance()
  local pose = instance:evaluatePose()
  Assert.near(pose.nodeMatrices[0][1], 1, 1e-9)
  Assert.isNil(pose.nodeVisible[0], "no visibility animation: the node stays visible")
  Assert.near(swingCell(instance), 1, 1e-9)
end

function T.rigid_node_animation_moves_the_draw()
  local instance = newInstance()
  instance:play("door.open")
  instance:updateFixed() -- frame 1
  instance:evaluatePose()
  local c1 = swingCell(instance)
  Assert.isTrue(c1 < 1, "the swinging door rotates away from the bind pose")

  for _ = 1, 6 do
    instance:updateFixed()
  end
  instance:evaluatePose()
  local c7 = swingCell(instance)
  Assert.isTrue(c7 < c1, "the swing continues toward the peak")
  -- The final frame's rotation differs from the bind pose.
  Assert.isTrue(math.abs(c7 - 1) > 0.01)
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
  -- a at frame 3 (opening), b at frame 5 going backward (also opening);
  -- their rotation cells must differ from each other and from the bind pose.
  local ma, mb = swingCell(a), swingCell(b)
  Assert.isTrue(ma < 1 and mb < 1, "both instances rotated off the bind pose")
  Assert.isFalse(ma == mb, "per-instance playback state")
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
  ok = pcall(instance.play, instance, "door.open", { direction = 2 })
  Assert.isFalse(ok, "direction must be +-1")
  Assert.equal(#instance.animationState:attachments("joint"), 0, "failed plays attach nothing")
end

-- Concurrent clips on one node blend by attachment ratio: at frame 0 the
-- open clip is the identity rotation and the close clip is the peak swing,
-- so a 50/50 cell blend with the basis-vector rebuild lands on the
-- half-angle (rotation about Y: cos(45deg) = 0.7071).
function T.concurrent_clips_blend_on_the_same_node()
  local instance = newInstance()
  instance:play("door.open")
  instance:play("door.close")
  instance:evaluatePose()
  Assert.near(swingCell(instance), math.cos(math.pi / 4), 1e-3)
end

-- ---- draw items ----

function T.draw_items_carry_pose_transforms()
  local instance = newInstance()
  instance:play("door.open")
  instance:updateFixed()
  instance:evaluatePose()
  local items = instance:drawItems(rendersFor(instance.definition))
  Assert.equal(#items, 1)
  Assert.near(items[1].transform[1], swingCell(instance), 1e-9, "the draw transform carries the pose")
  -- The per-segment polygon state rides on the item.
  Assert.equal(items[1].cullMode, "back")
  Assert.equal(items[1].polygonMode, "modulation")
  Assert.equal(items[1].polygonId, 0)
  Assert.equal(items[1].translucentDepthWrite, false)
end

function T.draw_items_compose_the_instance_transform()
  local def = NitroModelFixture.doorDefinition()
  def.meshes[1].center = { 1, 1, 0 }
  local instance = ModelInstance.new(def, {
    transform = Matrix4.translate(10, 0, 20),
  })
  instance:evaluatePose()
  local items = instance:drawItems(rendersFor(instance.definition))
  Assert.equal(#items, 1)
  Assert.equal(items[1].transform[13], 10)
  Assert.equal(items[1].transform[15], 20)
  -- The center stays model-local: the render queue transforms it once.
  Assert.deepEqual(items[1].center, { 1, 1, 0 })
end

function T.material_contract_maps_to_render_state()
  local instance = newInstance()
  local wall = instance:effectiveMaterial(0)
  Assert.equal(wall.alphaClass, "opaque")
  Assert.equal(wall.polygonAlpha, 1.0)
  -- Instance state overrides never touch the definition.
  instance.materialState[0].polygonAlpha = 16
  Assert.near(instance:effectiveMaterial(0).polygonAlpha, 16 / 31, 1e-9)
  Assert.equal(instance.definition.materials[1].baseColor.a, 255)
end

-- The resolveImage callback contract: effectiveMaterial invokes it with the
-- texture key only -- the stale width/height arguments are gone.
function T.resolve_image_receives_only_the_texture_key()
  local calls = {}
  local instance = ModelInstance.new(texturedDoorDefinition(), {
    resolveImage = function(...)
      calls[#calls + 1] = { ... }
    end,
  })
  local material = instance:effectiveMaterial(0)
  Assert.equal(#calls, 1, "the textured material resolves an image")
  Assert.equal(#calls[1], 1, "the resolveImage callback receives exactly the texture key")
  Assert.equal(calls[1][1], "wall.png")
  Assert.isNil(material.image, "the callback return value passes through")
end

-- ---- nitro backend contract ----

function T.nitro_backend_without_a_program_raises()
  local def = NitroModelFixture.doorDefinition()
  def.backend = { meshes = {} }
  local instance = ModelInstance.new(def)
  throwsCode("POSE_NITRO_NO_TRANSFORM_PROGRAM", function()
    return instance:evaluatePose()
  end)
  -- Without a pose the draw path falls back to bind placement rather than
  -- pretending to animate.
  local items = instance:drawItems(rendersFor(def))
  Assert.equal(#items, 1)
  Assert.equal(items[1].transform[1], 1)
end

function T.unknown_backend_source_raises()
  local def = ModelDefinition.new({
    key = "fixture:bad",
    sourceBackend = "nitro",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = { { id = "m", nodeIndex = 0, materialIndex = 0, batch = { vertices = {}, indices = {} } } },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
      },
    },
    animations = {},
    backend = { program = nil, meshes = {} },
  })
  local instance = ModelInstance.new(def)
  throwsCode("POSE_NITRO_NO_TRANSFORM_PROGRAM", function()
    return instance:evaluatePose()
  end)
end

return T
