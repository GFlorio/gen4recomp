-- Turns presentation-neutral actor draw records into FieldRenderer draw items.
--
-- Ordinary actor visuals are native-resolution opaque/cutout presentation
-- billboards. They carry their world-space center and base scale for the
-- presentation shader, which samples the resolved world's DS depth but does
-- not write world renderState or receive world edge marking. Static-model
-- actor parts remain world actors: they use the world projection and join the
-- world color/state and edge passes with terrain and buildings.
--
-- Pure domain module: matrix arithmetic only, no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")

local FieldActorDraw = {}

---@class FieldActorDraw.Record
---@field actorId string
---@field spriteId integer
---@field world { x: number, y: number, z: number }
---@field facing string
---@field pose string?
---@field poseTick integer?
---@field gesturePose string?
---@field gestureTick integer?
---@field visible boolean?

---@class FieldActorDraw.Entry
---@field visual FieldActorCache.Visual
---@field meshes table<string, unknown>?
---@field image table<string, unknown>?
---@field billboardScales table<string, unknown>?

-- Draw items carry no submission numbers: queue traversal orders every part
-- and draw in source order, positionally.

-- The identity UV-transform matrix of actor materials (actors carry no
-- texture-SRT): the renderer reads the material's texMatrix directly.
local IDENTITY_TEX_MATRIX = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

---@param entry FieldActorDraw.Entry
---@param meshIndex integer
---@param record FieldActorDraw.Record
---@return table<string, unknown>
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
  error("unreachable")
end

---@param matrix number[]
---@param x number
---@param y number
---@param z number
local function writeTranslation(matrix, x, y, z)
  matrix[13] = x
  matrix[14] = y
  matrix[15] = z
end

---@param item table<string, unknown>
---@param x number
---@param y number
---@param z number
---@param baseTransform number[]
---@return number[]
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

---@param record FieldActorDraw.Record
---@param entry FieldActorDraw.Entry
---@param partIndex integer?
---@param item table<string, unknown>
---@return table<string, unknown>
local function writeItem(record, entry, partIndex, item)
  assert(type(record) == "table" and type(record.world) == "table", "a draw record needs a world position")
  assert(type(entry) == "table" and type(entry.visual) == "table", "a draw record needs its visual asset")
  local visual = entry.visual
  local render = visual.render
  ---@type FieldActorCache.StaticPart|FieldActorCache.AtlasRender
  local part
  if render.kind == "staticModel" then
    ---@cast render FieldActorCache.StaticRender
    part = assert(render.parts[partIndex or 1])
  else
    ---@cast render FieldActorCache.AtlasRender
    part = render
  end
  local geometry = assert(part.geometry, "draw visual part is missing geometry")
  local frameIndex, poseFellBack
  local gestureOffsetX, gestureOffsetY, gestureOffsetZ = 0, 0, 0
  if record.gesturePose ~= nil then
    frameIndex = FieldActorPose.gestureFrameIndex(visual, record.gesturePose, record.gestureTick or 0)
    poseFellBack = false
    local gesture = assert(visual.gestures[record.gesturePose], "unknown gesture " .. tostring(record.gesturePose))
    gestureOffsetX = gesture.displayOffset.x
    gestureOffsetY = gesture.displayOffset.y
    gestureOffsetZ = gesture.displayOffset.z
  else
    frameIndex, poseFellBack =
      FieldActorPose.frameIndex(visual, record.facing, record.pose or "idle", record.poseTick or 0)
  end

  local anchor = geometry.anchorTiles
  local x = record.world.x + gestureOffsetX + anchor.x
  local y = record.world.y + gestureOffsetY + anchor.y
  local z = record.world.z + gestureOffsetZ + anchor.z
  local isBillboard = render.kind ~= "staticModel"
  if isBillboard then
    ---@cast part FieldActorCache.AtlasRender
    ---@cast geometry FieldActorCache.AtlasGeometry
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

  local polygon = assert(part.polygon, "draw visual part is missing polygon metadata")
  if isBillboard then
    assert(
      part.alphaClass == "opaque" or part.alphaClass == "cutout",
      "ordinary billboard has unsupported alpha class: " .. tostring(part.alphaClass)
    )
  end
  local image = entry.image
  if not isBillboard then
    ---@cast part FieldActorCache.StaticPart
    if part.textured == false then
      image = nil
    end
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
---@param record FieldActorDraw.Record
---@param entry FieldActorDraw.Entry
---@param partIndex integer?
---@return table<string, unknown>
function FieldActorDraw.item(record, entry, partIndex)
  return writeItem(record, entry, partIndex, {})
end

---@class FieldActorDrawStorage
---@field items table[]
---@field actorSlots table<string, table<string, unknown>>
---@field generation integer

-- Draw items into caller-owned storage. The storage retains one skeleton per
-- live actor and static-model part, while the returned array is compacted on
-- every call so removed or hidden actors cannot leave stale submissions.
---@param records FieldActorDraw.Record[]
---@param assetFor fun(spriteId: integer): FieldActorDraw.Entry
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
      local partCount
      if render.kind == "staticModel" then
        ---@cast render FieldActorCache.StaticRender
        partCount = #render.parts
      else
        ---@cast render FieldActorCache.AtlasRender
        partCount = 1
      end
      local actorSlots = storage.actorSlots[record.actorId]
      if not actorSlots then
        actorSlots = {}
        storage.actorSlots[record.actorId] = actorSlots
      end
      actorSlots.generation = generation
      for partIndex = 1, partCount do
        ---@type FieldActorCache.StaticPart|FieldActorCache.AtlasRender
        local part
        if render.kind == "staticModel" then
          ---@cast render FieldActorCache.StaticRender
          part = assert(render.parts[partIndex])
        else
          ---@cast render FieldActorCache.AtlasRender
          part = render
        end
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
