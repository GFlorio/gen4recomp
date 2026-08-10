-- GenericPoseBackend: the source-neutral pose evaluator for models that do
-- not originate from Nitro formats (the "generic/glTF backend" of the pose
-- contract). It walks the definition's node hierarchy top-down (parents
-- precede children by contract), composes each node's local TRS in the glTF
-- convention (local = T * R * S), overlays the playing joint clips on the
-- nodes they bind, resolves visibility clips, and derives each skin's joint
-- palette as globalTransform x inverseBindMatrix.
--
-- Joint clip combination: for a node with several contributing attachments
-- the translation and scale lerp with weights normalized from the attachment
-- ratios; the rotation blends the first two basis rows and rebuilds the
-- third by cross product and normalization -- the same rotation blend
-- contract the Nitro path uses, so both backends output compatible
-- orientations. A node with one contributor takes it directly; absent
-- channels fall back to the node's static TRS.
--
-- Visibility combination matches Nitro's BlendVis: a node is hidden only
-- when every visibility attachment that targets it hides it (OR semantics);
-- nodes no attachment targets stay visible.
--
-- Frame values are the player's fixed-point frames sampled through
-- AnimationClip.sample (step/linear keys). Pure domain module: no love.

local Errors = require("libs.rom.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local AnimationClip = require("libs.engine.src.AnimationClip")

local GenericPoseBackend = {}

-- The joint clip channel names (see AnimationClip).
local CHANNEL = {
  TRANSLATION = "translation",
  ROTATION = "rotation",
  SCALE = "scale",
  VISIBLE = "visible",
}

local function identityMatrix()
  return Matrix4.identity()
end

local function rotationMatrix(rot)
  return {
    rot[1],
    rot[2],
    rot[3],
    0,
    rot[4],
    rot[5],
    rot[6],
    0,
    rot[7],
    rot[8],
    rot[9],
    0,
    0,
    0,
    0,
    1,
  }
end

local function translationMatrix(t)
  return Matrix4.translate(t.x, t.y, t.z)
end

local function scaleMatrix(s)
  return Matrix4.scale(s.x, s.y, s.z)
end

-- local = T * R * S (glTF convention, column-major).
local function localMatrix(trans, rot, scale)
  return Matrix4.multiply(Matrix4.multiply(translationMatrix(trans), rotationMatrix(rot)), scaleMatrix(scale))
end

-- The rotation blend used for multiple contributors on one node: cells 0-5
-- lerp with the given weights, then row2 = cross(row0, row1), rows 0 and 2
-- normalize, row1 = cross(row2, row0). Works on float 9-cell matrices.
local function orthonormalize(rot)
  local function cross(a, b)
    return {
      a[2] * b[3] - a[3] * b[2],
      a[3] * b[1] - a[1] * b[3],
      a[1] * b[2] - a[2] * b[1],
    }
  end
  local function normalize(v)
    local length = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    if length == 0 then
      return { 0, 0, 0 }
    end
    return { v[1] / length, v[2] / length, v[3] / length }
  end
  local row0 = normalize({ rot[1], rot[2], rot[3] })
  local row1 = { rot[4], rot[5], rot[6] }
  local row2 = normalize(cross(row0, row1))
  row1 = cross(row2, row0)
  return { row0[1], row0[2], row0[3], row1[1], row1[2], row1[3], row2[1], row2[2], row2[3] }
end

local function blendRotations(contributions)
  if #contributions == 1 then
    return contributions[1].rot
  end
  local rot = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  for i = 1, 6 do
    for _, c in ipairs(contributions) do
      rot[i] = rot[i] + c.weight * c.rot[i]
    end
  end
  return orthonormalize(rot)
end

-- True when `attachment` carries any track whose binding maps to `nodeIndex`.
local function bindsNode(attachment, nodeIndex)
  for _, track in ipairs(attachment.clip.tracks) do
    if attachment.binding:modelIndex(track.target) == nodeIndex then
      return true
    end
  end
  return false
end

-- Sample one channel of the first track of `attachment` that binds
-- `nodeIndex` and carries the channel; nil when the attachment leaves the
-- channel to the static node.
local function sampleForNode(attachment, nodeIndex, channelName)
  for _, track in ipairs(attachment.clip.tracks) do
    if attachment.binding:modelIndex(track.target) == nodeIndex and track.channels[channelName] then
      return AnimationClip.sample(attachment.clip, track.index, channelName, attachment.player.frameFx)
    end
  end
  return nil
end

-- Sample the rotation channel: linearly interpolated 9-cell matrices are
-- not rotations, so the interpolated cells are rebuilt with the engine's
-- basis-vector orthonormalization (the same contract the blend uses);
-- step keys are author-provided rotations and pass through unchanged.
local function sampleRotation(attachment, nodeIndex)
  for _, track in ipairs(attachment.clip.tracks) do
    local channel = track.channels and track.channels[CHANNEL.ROTATION]
    if channel and attachment.binding:modelIndex(track.target) == nodeIndex then
      local value = AnimationClip.sample(attachment.clip, track.index, CHANNEL.ROTATION, attachment.player.frameFx)
      if channel.interpolation == "linear" then
        value = orthonormalize(value)
      end
      return value
    end
  end
  return nil
end

-- The animated local TRS of one node: every joint attachment that binds this
-- node contributes the sampled channels it carries, blended by normalized
-- attachment ratios; unattached channels come from the static node.
local function animatedLocal(node, attachments, nodeIndex)
  local contributed = {}
  local totalRatio = 0
  for _, attachment in ipairs(attachments) do
    if attachment.ratioFx > 0 and bindsNode(attachment, nodeIndex) then
      contributed[#contributed + 1] = attachment
      totalRatio = totalRatio + attachment.ratioFx
    end
  end
  if #contributed == 0 then
    return localMatrix(node.translation, node.rotation, node.scale)
  end

  if #contributed == 1 then
    local attachment = contributed[1]
    local trans = sampleForNode(attachment, nodeIndex, CHANNEL.TRANSLATION) or node.translation
    local rot = sampleRotation(attachment, nodeIndex) or node.rotation
    local scale = sampleForNode(attachment, nodeIndex, CHANNEL.SCALE) or node.scale
    return localMatrix(trans, rot, scale)
  end

  assert(totalRatio > 0, "contributing joint attachments have zero total ratio")
  local weights = {}
  for _, attachment in ipairs(contributed) do
    weights[#weights + 1] = attachment.ratioFx / totalRatio
  end

  local function blendVec(get, fallback)
    local out = { 0, 0, 0 }
    for i, attachment in ipairs(contributed) do
      local value = get(attachment) or fallback
      out[1] = out[1] + weights[i] * value.x
      out[2] = out[2] + weights[i] * value.y
      out[3] = out[3] + weights[i] * value.z
    end
    return { x = out[1], y = out[2], z = out[3] }
  end

  local rotations = {}
  for i, attachment in ipairs(contributed) do
    local rot = sampleRotation(attachment, nodeIndex) or node.rotation
    rotations[#rotations + 1] = { weight = weights[i], rot = rot }
  end

  local trans = blendVec(function(a)
    return sampleForNode(a, nodeIndex, CHANNEL.TRANSLATION)
  end, node.translation)
  local scale = blendVec(function(a)
    return sampleForNode(a, nodeIndex, CHANNEL.SCALE)
  end, node.scale)
  local rot = blendRotations(rotations)
  return localMatrix(trans, rot, scale)
end

-- Effective per-node visibility: OR over the attachments that target each
-- node (Nitro BlendVis semantics); nodes no attachment targets stay visible.
local function evaluateVisibility(definition, attachments, nodeVisible)
  for nodeIndex = 0, #definition.nodes - 1 do
    local any, visible = false, false
    for _, attachment in ipairs(attachments) do
      for _, track in ipairs(attachment.clip.tracks) do
        if attachment.binding:modelIndex(track.target) == nodeIndex then
          any = true
          local value = AnimationClip.sample(attachment.clip, track.index, CHANNEL.VISIBLE, attachment.player.frameFx)
          if value then
            visible = true
          end
        end
      end
    end
    if any and not visible then
      nodeVisible[nodeIndex] = false
    end
  end
end

-- Evaluate `instance` into a PoseState (see PoseBackend). Joint and
-- visibility attachments are taken from the instance's animation state;
-- material attachments do not affect the pose.
function GenericPoseBackend.evaluate(instance)
  local def = instance.definition
  if def.sourceBackend ~= "generic" then
    Errors.raise(
      "POSE_BACKEND_SOURCE_MISMATCH",
      "GenericPoseBackend cannot evaluate a " .. def.sourceBackend .. " model (" .. def.key .. ")",
      { sourceBackend = def.sourceBackend, modelKey = def.key }
    )
  end
  local jointAttachments = instance.animationState:attachments("joint")
  local visibilityAttachments = instance.animationState:attachments("visibility")

  local nodeMatrices = {}
  local nodeVisible = {}
  for nodeIndex = 0, #def.nodes - 1 do
    local node = def.nodes[nodeIndex + 1]
    local base = nodeMatrices[node.parentIndex] or identityMatrix()
    local localM
    if #jointAttachments == 0 then
      localM = localMatrix(node.translation, node.rotation, node.scale)
    else
      localM = animatedLocal(node, jointAttachments, nodeIndex)
    end
    nodeMatrices[nodeIndex] = Matrix4.multiply(base, localM)
  end
  if #visibilityAttachments > 0 then
    evaluateVisibility(def, visibilityAttachments, nodeVisible)
  end

  local jointPalettes = {}
  for _, skin in ipairs(def.skins) do
    local palette = {}
    for _, joint in ipairs(skin.joints) do
      -- glTF convention: jointMatrix = globalTransform x inverseBindMatrix.
      palette[joint] = Matrix4.multiply(nodeMatrices[joint], skin.inverseBindMatrices[joint])
    end
    jointPalettes[skin.id] = palette
  end

  return { nodeMatrices = nodeMatrices, nodeVisible = nodeVisible, jointPalettes = jointPalettes }
end

return GenericPoseBackend
