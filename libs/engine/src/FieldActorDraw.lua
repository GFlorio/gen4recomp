-- Turns presentation-neutral actor draw records into map-renderer draw items.
--
-- An actor is world geometry, not UI: it enters the same queue as terrain and
-- building batches and carries the polygon state the ROM's actor material
-- declares (modulation, full polygon alpha, polygon id 0, colour-zero cutout),
-- so it depth-tests against map geometry and takes part in edge marking exactly
-- as the original does. The quad is a Nitro full camera-facing billboard, so the
-- item ships its world-space center and base scale; the vertex shader supplies
-- the camera-facing axes without rebuilding a model matrix on the CPU.
--
-- Pure domain module: matrix arithmetic only, no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldActorPose = require("libs.engine.src.FieldActorPose")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")

local FieldActorDraw = {}

-- Draw items carry no submission numbers: queue traversal orders every part
-- and draw in source order, positionally.

-- The identity UV-transform matrix of actor materials (actors carry no
-- texture-SRT): the renderer reads the material's texMatrix directly.
local IDENTITY_TEX_MATRIX = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

local function requireMesh(entry, meshIndex, record)
  local mesh = entry.meshes and entry.meshes[meshIndex]
  if mesh then
    return mesh
  end
  Errors.raise(
    FieldErrors.ACTOR_DRAW_FRAME_MISSING,
    "actor "
      .. tostring(record.actorId)
      .. " selected mesh "
      .. tostring(meshIndex)
      .. ", which the resident visual does not provide",
    { actorId = record.actorId, spriteId = record.spriteId, frameIndex = meshIndex }
  )
end

local function writeTranslation(matrix, x, y, z)
  matrix[13] = x
  matrix[14] = y
  matrix[15] = z
end

local function writeBillboardBase(item, x, y, z, baseTransform)
  local billboardBase = item.billboardBase
  if not billboardBase then
    billboardBase = Matrix4.multiply(Matrix4.translate(x, y, z), baseTransform)
    item.billboardBase = billboardBase
    item.transform = billboardBase
  else
    writeTranslation(billboardBase, x + baseTransform[13], y + baseTransform[14], z + baseTransform[15])
  end
  return billboardBase
end

local function writeItem(record, entry, partIndex, item)
  assert(type(record) == "table" and type(record.world) == "table", "a draw record needs a world position")
  assert(type(entry) == "table" and type(entry.visual) == "table", "a draw record needs its visual asset")
  local visual = entry.visual
  local render = visual.render
  local part = render.kind == "staticModel" and assert(render.parts[partIndex or 1]) or render
  local geometry = part.geometry
  local frameIndex, poseFellBack =
    FieldActorPose.frameIndex(visual, record.facing, record.pose or "idle", record.poseTick or 0)

  local anchor = geometry.anchorTiles
  local x = record.world.x + anchor.x
  local y = record.world.y + anchor.y
  local z = record.world.z + anchor.z
  local isBillboard = render.kind ~= "staticModel"
  if isBillboard then
    local billboardBase = writeBillboardBase(item, x, y, z, geometry.baseTransform)
    local billboardCenter = item.billboardCenter or {}
    billboardCenter[1] = billboardBase[13]
    billboardCenter[2] = billboardBase[14]
    billboardCenter[3] = billboardBase[15]
    item.billboardCenter = billboardCenter
    item.billboardScale = assert(
      entry.billboardScales and entry.billboardScales[geometry],
      "resident billboard visual is missing its precomputed scale"
    )
  else
    if not item.transform then
      item.transform = Matrix4.translate(x, y, z)
    else
      writeTranslation(item.transform, x, y, z)
    end
    item.billboardBase = nil
    item.billboardCenter = nil
    item.billboardScale = nil
  end

  local polygon = part.polygon
  local image = entry.image
  if part.textured == false then
    image = nil
  end
  local material = item.material or {}
  material.image = image
  material.alphaClass = part.alphaClass
  material.texMatrix = IDENTITY_TEX_MATRIX
  item.material = material

  item.mesh = requireMesh(entry, render.kind == "staticModel" and (partIndex or 1) or frameIndex, record)
  item.modelNormal = IDENTITY_MODEL_NORMAL
  item.billboardProjection = isBillboard
  item.alphaClass = part.alphaClass
  item.cullMode = polygon.cullMode
  item.polygonAlpha = polygon.polygonAlpha / FixedPoint.RGB5_MAX
  item.polygonMode = polygon.polygonMode
  item.lightMask = polygon.lightMask
  item.polygonId = polygon.polygonId
  item.translucentDepthWrite = polygon.translucentDepthWrite
  item.depthEqual = polygon.depthEqual
  item.fogEnabled = polygon.fogEnabled
  item.center = geometry.center or item.center or { 0, geometry.bounds.height / 2, 0 }
  item.actorId = record.actorId
  item.spriteId = record.spriteId
  item.frameIndex = frameIndex
  item.poseFellBack = poseFellBack
  return item
end

-- record: an ActorDrawRecord (actorId, spriteId, world, facing, pose, poseTick).
-- entry: the resident FieldActorAssetProvider entry for that sprite.
-- partIndex: for a static model, the part to draw (1-based).
function FieldActorDraw.item(record, entry, partIndex)
  return writeItem(record, entry, partIndex, {})
end

---@class FieldActorDrawStorage
---@field items table[]
---@field actorSlots table<string, table>
---@field generation integer

-- Draw items into caller-owned storage. The storage retains one skeleton per
-- live actor and static-model part, while the returned array is compacted on
-- every call so removed or hidden actors cannot leave stale submissions.
---@param records table[]
---@param assetFor fun(spriteId: integer): table
---@param storage FieldActorDrawStorage
---@return table[]
function FieldActorDraw.itemsInto(records, assetFor, storage)
  assert(type(assetFor) == "function", "FieldActorDraw.itemsInto needs an asset lookup")
  assert(type(storage) == "table" and storage.items and storage.actorSlots, "FieldActorDraw storage is incomplete")
  storage.generation = (storage.generation or 0) + 1
  local generation = storage.generation
  local items = storage.items
  local itemCount = 0
  for _, record in ipairs(records) do
    if record.visible ~= false then
      local entry = assetFor(record.spriteId)
      if not entry then
        Errors.raise(
          FieldErrors.ACTOR_DRAW_VISUAL_MISSING,
          "actor " .. tostring(record.actorId) .. " has no resident visual for spriteId " .. tostring(record.spriteId),
          { actorId = record.actorId, spriteId = record.spriteId }
        )
      end
      local render = entry.visual.render
      local partCount = render.kind == "staticModel" and #render.parts or 1
      local actorSlots = storage.actorSlots[record.actorId]
      if not actorSlots then
        actorSlots = {}
        storage.actorSlots[record.actorId] = actorSlots
      end
      actorSlots.generation = generation
      for partIndex = 1, partCount do
        local part = render.kind == "staticModel" and render.parts[partIndex] or render
        local slot = actorSlots[partIndex]
        if not slot or slot.entry ~= entry or slot.part ~= part then
          slot = { entry = entry, part = part, item = {} }
          actorSlots[partIndex] = slot
        end
        itemCount = itemCount + 1
        items[itemCount] = writeItem(record, entry, render.kind == "staticModel" and partIndex or nil, slot.item)
      end
      for partIndex = #actorSlots, partCount + 1, -1 do
        actorSlots[partIndex] = nil
      end
    elseif storage.actorSlots[record.actorId] then
      -- Keep a live hidden actor's skeleton so visibility changes do not
      -- churn its item state; it still contributes no submission this call.
      storage.actorSlots[record.actorId].generation = generation
    end
  end
  for index = #items, itemCount + 1, -1 do
    items[index] = nil
  end
  for actorId, actorSlots in pairs(storage.actorSlots) do
    if actorSlots.generation ~= generation then
      storage.actorSlots[actorId] = nil
    end
  end
  return items
end

-- Convenience wrapper over itemsInto with fresh, single-use storage. Steady
-- presentation callers hold their own storage and call itemsInto directly.
function FieldActorDraw.items(records, assetFor)
  return FieldActorDraw.itemsInto(records, assetFor, { items = {}, actorSlots = {}, generation = 0 })
end

return FieldActorDraw
