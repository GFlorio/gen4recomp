-- NsbmdPoseProvider: the pose providers that feed NsbmdSbcEvaluator.
--
--   BindPoseProvider  -- every node at its model bind SRT; the static path
--   NsbcaPoseProvider -- nodes animated by NSBCA clips, blended per node
--                       like NitroSystem's NNSi_G3dAnmBlendJnt
--
-- Both implement the pose-provider contract consumed by
-- NsbmdSbcEvaluator.evaluate(program, poseProvider):
--
--   nodeSRT(nodeIndex) -> SRT record | nil
--       -- nil falls back to the program's bind SRT
--   nodeVisible(nodeIndex) -> boolean | nil
--       -- visibility override; nil lets the SBC NODE command decide
--
-- The animated provider samples its clips through Nsbca.sample (raw decoded
-- resources, digest-side), converts each sample into the NNSG3dAnmResult
-- shape, blends every attachment targeting a node through JointAnimBlend
-- (the exact asm semantics), and composes the result into an SRT record via
-- NitroJointState.srtFromBlend. The engine's runtime backend follows the
-- same steps over compiled clips (CompiledNsbcaSampler), so both paths
-- share the blend and composition math. Pure domain module.

local JointAnimBlend = require("libs.engine.src.JointAnimBlend")
local NitroJointState = require("libs.engine.src.NitroJointState")
local Nsbca = require("romdump.src.digest.nitro.Nsbca")

local NsbmdPoseProvider = {}

-- Convert one Nsbca.sample result into the NNSG3dAnmResult shape
-- JointAnimBlend consumes: fx32 words for every sampled channel and the
-- from-model flags, with the inverse-scale flag following the scale channel
-- (Nsbca.sample reports one scaleFromModel for the pair).
local function resultFromSample(sample)
  local flags = 0
  if sample.scaleFromModel then
    flags = flags + JointAnimBlend.FROM_MODEL.scale + JointAnimBlend.FROM_MODEL.inverseScale
  end
  if sample.rotFromModel then
    flags = flags + JointAnimBlend.FROM_MODEL.rot
  end
  if sample.transFromModel then
    flags = flags + JointAnimBlend.FROM_MODEL.trans
  end
  return {
    flags = flags,
    scale = {
      sample.scale and sample.scale.x or 0,
      sample.scale and sample.scale.y or 0,
      sample.scale and sample.scale.z or 0,
    },
    scaleEx = {
      sample.inverseScale and sample.inverseScale.x or 0,
      sample.inverseScale and sample.inverseScale.y or 0,
      sample.inverseScale and sample.inverseScale.z or 0,
    },
    rot = sample.rot or { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    trans = {
      sample.trans and sample.trans.x or 0,
      sample.trans and sample.trans.y or 0,
      sample.trans and sample.trans.z or 0,
    },
  }
end

-- ---- bind pose ----

-- A provider that returns the model's decoded node records unchanged.
-- nodeSRT falls back to nil for nodes the model does not carry (the
-- evaluator then raises, exactly like the static path).
function NsbmdPoseProvider.bindPose(model)
  local nodes = model.nodes
  return {
    nodeSRT = function(nodeIndex)
      assert(type(nodeIndex) == "number", "nodeSRT requires a numeric node index")
      return nodes[nodeIndex + 1]
    end,
  }
end

-- ---- NSBCA-animated pose ----

-- An attachment descriptor:
--   { resource = <decoded Nsbca record>,
--     reader   = <the JNT0 section BinaryReader Nsbca.sample needs>,
--     ratio    = <fx32, default 0x1000> }
local NsbcaPoseProvider = {}
NsbcaPoseProvider.__index = NsbcaPoseProvider

-- Sample + blend every attachment targeting one node.
local function blendNode(self, entries)
  local contributed = {}
  for _, entry in ipairs(entries) do
    local sample = Nsbca.sample(entry.reader, entry.resource, entry.targetIndex, self.frameFx)
    contributed[#contributed + 1] = {
      ratio = entry.ratio,
      result = resultFromSample(sample),
    }
  end
  return JointAnimBlend.blend(contributed)
end

-- Build an animated provider over `program`'s nodes.
--   opts.attachments  list of attachment descriptors; a resource's targets
--                     whose node index is absent from the program are
--                     ignored (Nitro's permissive binding)
--   opts.frameFx      the fixed-point frame to sample (mutable: call
--                     provider:setFrameFx(frameFx) to scrub)
function NsbmdPoseProvider.nsbcaPose(program, opts)
  assert(type(program) == "table" and program.nodes ~= nil, "nsbcaPose requires a transform program")
  opts = opts or {}
  assert(type(opts.attachments) == "table", "nsbcaPose requires attachments")

  -- nodeIndex -> { { ratio, targetIndex, resource, reader }, ... } so the
  -- per-frame work is only sampling and blending.
  local byNode = {}
  for _, attachment in ipairs(opts.attachments) do
    local ratio = attachment.ratio or 0x1000
    assert(ratio > 0, "an NSBCA attachment needs a positive ratio")
    assert(attachment.reader ~= nil, "an NSBCA attachment needs the section reader")
    for _, target in ipairs(attachment.resource.targets) do
      local nodeIndex = target.nodeIndex
      if program.nodes[nodeIndex + 1] then
        local list = byNode[nodeIndex] or {}
        list[#list + 1] = {
          ratio = ratio,
          targetIndex = target.index,
          resource = attachment.resource,
          reader = attachment.reader,
        }
        byNode[nodeIndex] = list
      end
    end
  end

  local provider = setmetatable({
    program = program,
    byNode = byNode,
    frameFx = opts.frameFx or 0,
  }, NsbcaPoseProvider)
  provider.nodeSRT = function(nodeIndex)
    assert(type(nodeIndex) == "number", "nodeSRT requires a numeric node index")
    local entries = byNode[nodeIndex]
    if not entries then
      return nil
    end
    local blended = blendNode(provider, entries)
    if not blended then
      return nil
    end
    return NitroJointState.srtFromBlend(blended, program.nodes[nodeIndex + 1])
  end
  return provider
end

-- Scrub the provider to `frameFx` (clamped into [0, numFrame << 12 - 1] by
-- the sampler itself).
function NsbcaPoseProvider:setFrameFx(frameFx)
  self.frameFx = frameFx
end

return NsbmdPoseProvider
