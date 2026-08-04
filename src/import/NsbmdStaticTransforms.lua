-- Static evaluator for an NSBMD model's SBC draw stream.
--
-- NitroSystem's SBC commands drive the DS geometry engine's matrix stack:
-- NODEDESC computes joint matrices, POSSCALE folds the model header's posScale
-- in and out, MTX restores a stored slot, and SHP issues a shape draw. This
-- module replays those commands without LÖVE to produce, for every draw, the
-- position matrix and matrix-slot snapshot that the shape's display list must
-- inherit. See GBATEK "DS Video Geometry Commands" and NitroSystem g3d/sbc for
-- the command semantics; Nsbmd.lua already decodes the operands.
--
-- Out of scope (fail loudly): billboards (BB/BBY), skinning (NODEMIX),
-- non-standard scaling rules, and NODEDESC flags beyond plain joints.
--
-- Pure domain module: no love dependency.

local Errors = require("src.import.Errors")
local Matrix4 = require("src.render.Matrix4")

local NsbmdStaticTransforms = {}

local function copyMatrix(m)
  return Matrix4.toArray(m)
end

local function copyRestoreStack(stack)
  local copy = {}
  for slot, matrix in pairs(stack) do
    copy[slot] = copyMatrix(matrix)
  end
  return copy
end

local function slotOrIdentity(slots, slot)
  local m = slots[slot]
  return m and copyMatrix(m) or Matrix4.identity()
end

local function assertSupportedModel(model)
  if model.info.scalingRule ~= 0 then
    Errors.raise("NSBMD_STATIC_UNSUPPORTED_SCALING_RULE",
      "only standard scaling rule (0) is supported by static SBC evaluation",
      { scalingRule = model.info.scalingRule, model = model.name })
  end
end

-- Replay the SBC stream for `model` and return the ordered draw submissions.
-- Each submission is:
--   {
--     nodeIndex = <number>,
--     materialIndex = <number>,
--     shapeIndex = <number>,
--     materialReapplied = <boolean>,
--     matrix = <16-element column-major matrix>,
--     restoreStack = { [slot] = <matrix>, ... }
--   }
function NsbmdStaticTransforms.evaluate(model)
  assertSupportedModel(model)

  local currentMatrix = Matrix4.identity()
  local matrixSlots = {}
  local nodeMatrices = {}
  local nodeVisibility = {}
  local currentNode = 0
  local currentMaterial = 0
  local materialReapplied = true

  local draws = {}

  for _, cmd in ipairs(model.sbc.commands) do
    local op = cmd.opcode

    if op == 0x01 then -- RET
      break
    elseif op == 0x02 then -- NODE
      currentNode = cmd.nodeIndex
      nodeVisibility[cmd.nodeIndex] = cmd.visible
    elseif op == 0x03 then -- MTX
      currentMatrix = slotOrIdentity(matrixSlots, cmd.matrixSlot)
    elseif op == 0x04 then -- MAT
      currentMaterial = cmd.materialIndex
      materialReapplied = true
    elseif op == 0x05 then -- SHP
      if nodeVisibility[currentNode] ~= false then
        draws[#draws + 1] = {
          nodeIndex = currentNode,
          materialIndex = currentMaterial,
          shapeIndex = cmd.shapeIndex,
          materialReapplied = materialReapplied,
          matrix = copyMatrix(currentMatrix),
          restoreStack = copyRestoreStack(matrixSlots),
        }
      end
      materialReapplied = false
    elseif op == 0x06 then -- NODEDESC
      local node = model.nodes[cmd.nodeIndex + 1]
      if not node then
        Errors.raise("NSBMD_STATIC_NODE_NOT_FOUND",
          "NODEDESC references node index " .. tostring(cmd.nodeIndex),
          { nodeIndex = cmd.nodeIndex, model = model.name })
      end

      if cmd.flags ~= 0 then
        Errors.raise("NSBMD_STATIC_NODEDESC_FLAGS_UNSUPPORTED",
          "NODEDESC flags " .. tostring(cmd.flags) .. " are not supported",
          { flags = cmd.flags, nodeIndex = cmd.nodeIndex, model = model.name })
      end

      local baseMatrix
      if cmd.restoreSlot ~= nil then
        baseMatrix = slotOrIdentity(matrixSlots, cmd.restoreSlot)
      elseif cmd.parentIndex ~= cmd.nodeIndex and nodeMatrices[cmd.parentIndex] then
        baseMatrix = copyMatrix(nodeMatrices[cmd.parentIndex])
      else
        baseMatrix = Matrix4.identity()
      end

      local world = Matrix4.multiply(baseMatrix, node.localMatrix)
      nodeMatrices[cmd.nodeIndex] = world
      matrixSlots[node.matrixStackIndex] = world
      if cmd.storeSlot ~= nil then
        matrixSlots[cmd.storeSlot] = world
      end
      currentMatrix = copyMatrix(world)
      currentNode = cmd.nodeIndex
    elseif op == 0x07 or op == 0x08 or op == 0x09 then -- BB, BBY, NODEMIX
      Errors.raise("NSBMD_STATIC_UNSUPPORTED_SBC_COMMAND",
        cmd.name .. " is not supported by static SBC evaluation",
        { opcode = op, command = cmd.command, offset = cmd.offset, model = model.name })
    elseif op == 0x0B then -- POSSCALE
      local scale = cmd.inverse and model.info.invPosScale or model.info.posScale
      currentMatrix = Matrix4.multiply(currentMatrix, Matrix4.scale(scale, scale, scale))
    end
  end

  return draws
end

return NsbmdStaticTransforms
