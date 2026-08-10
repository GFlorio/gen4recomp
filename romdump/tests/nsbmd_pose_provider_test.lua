-- Tests for NsbmdPoseProvider: the bind-pose and NSBCA-animated pose
-- providers feeding NsbmdSbcEvaluator. Models are decoded Nsbmd fixtures;
-- clips are AnimationFixture NSBCA resources decoded through
-- NitroAnimation. The composition math (sampling -> JointAnimBlend ->
-- NitroJointState.srtFromBlend) is exercised end to end through the
-- evaluator's draw matrices.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.rom.src.BinaryReader")
local NitroAnimation = require("romdump.src.digest.nitro.NitroAnimation")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local NsbmdSbcEvaluator = require("libs.engine.src.NsbmdSbcEvaluator")
local NsbmdTransformProgram = require("romdump.src.digest.NsbmdTransformProgram")
local NsbmdPoseProvider = require("romdump.src.digest.NsbmdPoseProvider")
local ModelFixture = require("tests.support.NsbmdModelFixture")
local AnimationFixture = require("tests.support.AnimationFixture")
local NB = require("tests.support.NitroBuilder")

local T = {}

local function u32(v)
  return NB.u32(v)
end

local EPS = 1e-9

local function assertVecAt(m, x, y, z, ex, ey, ez, msg)
  local ax = m[1] * x + m[5] * y + m[9] * z + m[13]
  local ay = m[2] * x + m[6] * y + m[10] * z + m[14]
  local az = m[3] * x + m[7] * y + m[11] * z + m[15]
  if math.abs(ax - ex) > EPS or math.abs(ay - ey) > EPS or math.abs(az - ez) > EPS then
    error(
      (msg or "transform mismatch")
        .. ": expected ("
        .. ex
        .. ","
        .. ey
        .. ","
        .. ez
        .. "), got ("
        .. ax
        .. ","
        .. ay
        .. ","
        .. az
        .. ")"
    )
  end
end

-- A decoded model with one translated node and one draw.
local function translatedModel()
  local nodeData = ModelFixture.transformedNodeData(1, 2, 3, 1, 1, 1, 0)
  local nodeDict0 = NB.dict({ { name = "root", data = u32(0) } })
  local nodeDict = NB.dict({ { name = "root", data = u32(#nodeDict0) } })
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 1)
    .. string.char(0x04, 0)
    .. string.char(0x05, 0)
    .. string.char(0x01)
  return ModelFixture.decodeModel(nodeDict, nodeData, sbc)
end

-- Decode an AnimationFixture NSBCA file into { resource, reader }.
local function decodeClip(bytes)
  local decoded = assert(NitroAnimation.decode(bytes))
  local anim = assert(decoded.animations[1])
  return anim.resource, BinaryReader.new(decoded.bytes, "sec")
end

local function fx32(v)
  return math.floor(v * 4096) % 4294967296
end

-- A minimal BCA0 clip: one target on node 0 with constant translation
-- (10,20,30) and rotation/scale from the model. Flag 0x6F8 = trans consts +
-- rot from model (0xC0) + scale from model (0x600).
local function transConstClip()
  local record = "J\0AC"
    .. NB.u16(2)
    .. NB.u16(1)
    .. NB.u32(0)
    .. NB.u32(0)
    .. NB.u32(0) -- ofsRotData / ofsPivotData (unused)
    .. NB.u16(0x16) -- ofsTarget[0]
    .. NB.u32(0x6F8)
    .. NB.u32(fx32(10))
    .. NB.u32(fx32(20))
    .. NB.u32(fx32(30))
  local probe = NB.dict({ { name = "trans", data = NB.u32(0) } })
  local dict = NB.dict({ { name = "trans", data = NB.u32(8 + #probe) } })
  return NB.file("BCA0", { { magic = "JNT0", body = dict .. record } })
end

local function evaluateWith(model, provider)
  local program = NsbmdTransformProgram.compile(model)
  return NsbmdSbcEvaluator.evaluate(program, provider).draws[1]
end

-- ---- bind pose ----

function T.bind_provider_reproduces_the_static_draw_matrix()
  local model = translatedModel()
  local draws =
    NsbmdSbcEvaluator.evaluate(NsbmdTransformProgram.compile(model), NsbmdPoseProvider.bindPose(model)).draws
  assertVecAt(draws[1].matrix, 0, 0, 0, 1, 2, 3, "bind translation")
end

-- ---- NSBCA animated pose ----

-- jntDoor: rot pivot curve over 8 frames; trans and scale from the model.
function T.rotation_clip_with_model_translation_and_scale()
  local model = translatedModel()
  local resource, reader = decodeClip(AnimationFixture.jntDoor())
  local provider = NsbmdPoseProvider.nsbcaPose(
    NsbmdTransformProgram.compile(model),
    { attachments = { { resource = resource, reader = reader } } }
  )

  -- Frame 7: A = 9/16, B = 7/16; translation stays at the bind (1,2,3).
  provider:setFrameFx(7 * 4096)
  local draw = evaluateWith(model, provider)
  assertVecAt(draw.matrix, 0, 0, 0, 1, 2, 3, "bind translation preserved")
  assertVecAt(draw.matrix, 1, 0, 0, 1 + 9 / 16, 2, 3 + 7 / 16, "pivot rotation applied")

  -- Frame 0: identity rotation.
  provider:setFrameFx(0)
  local draw0 = evaluateWith(model, provider)
  assertVecAt(draw0.matrix, 1, 0, 0, 2, 2, 3, "frame 0 rotation is identity")
end

-- jntConstants target 0: constant translation (10, 20, 30), rot and scale
-- from the model. The clip targets node index 1, so the model needs node 1.
function T.constant_translation_with_model_rotation_and_scale()
  local node0Data = ModelFixture.transformedNodeData(0, 0, 0, 1, 1, 1, 0)
  local node1Data = ModelFixture.transformedNodeData(1, 1, 1, 2, 1, 1, 1)
  local nodeData = node0Data .. node1Data
  local nodeDict0 = NB.dict({
    { name = "a", data = u32(0) },
    { name = "b", data = u32(#node0Data) },
  })
  local nodeDict = NB.dict({
    { name = "a", data = u32(#nodeDict0) },
    { name = "b", data = u32(#nodeDict0 + #node0Data) },
  })
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x06, 1, 1, 0)
    .. string.char(0x04, 0)
    .. string.char(0x05, 0)
    .. string.char(0x01)
  local model = ModelFixture.decodeModel(nodeDict, nodeData, sbc, { numNode = 2 })

  local resource, reader = decodeClip(AnimationFixture.jntConstants())
  local program = NsbmdTransformProgram.compile(model)
  local provider = NsbmdPoseProvider.nsbcaPose(program, { attachments = { { resource = resource, reader = reader } } })

  -- Target 0 binds node 1: translation (10,20,30) on top of the bind
  -- translation (1,1,1), bind scale (2,1,1) retained.
  local srt = assert(provider.nodeSRT(1))
  Assert.equal(srt.translation.x, 10)
  Assert.equal(srt.translation.y, 20)
  Assert.equal(srt.translation.z, 30)
  Assert.equal(srt.scale.x, 2)
  Assert.isNil(provider.nodeSRT(0), "node 0 is unaffected (no target)")

  local draws = NsbmdSbcEvaluator.evaluate(program, provider).draws
  -- The animated translation replaces the bind translation (only channels
  -- marked "from model" use the bind values).
  assertVecAt(draws[1].matrix, 0, 0, 0, 10, 20, 30, "constant trans replaces bind trans")
  assertVecAt(draws[1].matrix, 1, 0, 0, 12, 20, 30, "bind scale retained on x")
end

-- Two clips on one node blend through JointAnimBlend: jntDoor's rotation
-- plus a node-0 trans-constant clip, each at ratio 0x1000.
function T.two_clips_blend_per_node()
  local model = translatedModel()
  local doorResource, doorReader = decodeClip(AnimationFixture.jntDoor())
  local constResource, constReader = decodeClip(transConstClip())
  local program = NsbmdTransformProgram.compile(model)
  local provider = NsbmdPoseProvider.nsbcaPose(program, {
    attachments = {
      { resource = doorResource, reader = doorReader },
      { resource = constResource, reader = constReader },
    },
  })

  -- Both clips bind node 0. At equal ratios (total 0x2000) each weight is
  -- 0x800: the constant clip contributes half its translation (5,10,15);
  -- the door clip's from-model translation contributes nothing (Nitro's
  -- blend skips from-model channels), and the flags AND leaves the
  -- translation as the blended value. The rotation is the door clip's
  -- halved and renormalized, so the matrix is neither identity nor the
  -- unblended door pose.
  provider:setFrameFx(7 * 4096)
  local draw = evaluateWith(model, provider)
  assertVecAt(draw.matrix, 0, 0, 0, 5, 10, 15, "blended translation (half each)")
  -- The door rotation at frame 7 alone maps (1,0,0) to (A,B) = (9/16,7/16);
  -- the blended rotation is halved and renormalized, so the x-axis mapping
  -- must differ from both the unblended door pose and the identity.
  local xmapped = { draw.matrix[1], draw.matrix[3] }
  Assert.isTrue(xmapped[1] > 0 and xmapped[2] > 0, "rotation leans toward the door clip's swing")
  Assert.isTrue(
    math.abs(xmapped[1] - 9 / 16) > 0.01 or math.abs(xmapped[2] - 7 / 16) > 0.01,
    "blended rotation differs from the unblended door pose"
  )
end

-- A clip whose targets name absent nodes is ignored, not fatal (Nitro's
-- permissive binding), and leaves the node on its bind SRT.
function T.clip_targets_without_model_nodes_are_ignored()
  local model = translatedModel()
  local resource, reader = decodeClip(AnimationFixture.jntConstants())
  local program = NsbmdTransformProgram.compile(model)
  local provider = NsbmdPoseProvider.nsbcaPose(program, { attachments = { { resource = resource, reader = reader } } })
  Assert.isNil(provider.nodeSRT(0), "no target binds node 0")
  local draw = evaluateWith(model, provider)
  assertVecAt(draw.matrix, 0, 0, 0, 1, 2, 3, "bind SRT unchanged")
end

-- Scrubbing the provider between frames changes the pose deterministically.
function T.scrubbing_reaches_known_frames()
  local model = translatedModel()
  local resource, reader = decodeClip(AnimationFixture.jntDoor())
  local program = NsbmdTransformProgram.compile(model)
  local provider = NsbmdPoseProvider.nsbcaPose(program, { attachments = { { resource = resource, reader = reader } } })

  provider:setFrameFx(0)
  local srt0 = assert(provider.nodeSRT(0))
  provider:setFrameFx(7 * 4096)
  local srt7 = assert(provider.nodeSRT(0))
  Assert.equal(srt0.rotation[1], 1)
  Assert.equal(srt7.rotation[1], 9 / 16)
  Assert.equal(srt7.rotation[3], 7 / 16)
end

return T
