-- Pure render-queue builder. Traverses ordered scene parts (map, building,
-- neighbour, and actor), partitions their draw items into opaque / cutout /
-- mixedOpaque / wireframe passes, and blended translucent/mixed-translucent
-- entries. Preserves source order for opaque/cutout/mixedOpaque/wireframe.
-- Sorts blended draws approximately back-to-front in camera space using the
-- item center and the view matrix. The item's traversal position across
-- ordered parts is the deterministic tie-breaker for equal-depth blended
-- draws, so the queue never invents cross-group ordering. This is an
-- explicit approximation of DS auto sorting, not a claim of exact hardware
-- ordering. Pure domain module: no love, arithmetic only.
--
-- Queue construction validates its input contract and never mutates the
-- caller's draw records: only the five known alpha classes are accepted
-- (anything else -- including a missing class -- fails loudly instead of
-- defaulting to opaque). Mixed items appear in mixedOpaque AND in blended
-- with fragmentPass="mixed"; blended contains decorated pass records
-- {item, fragmentPass, viewZ, position}, not original items. Translucent
-- items appear only in blended with fragmentPass="translucent". The sort
-- runs over local decorated entries so no field is written back onto
-- persistent items. The returned queue holds original items in
-- opaque/cutout/mixedOpaque/wireframe; blended holds decorated records.

local Errors = require("libs.errors.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")

local RenderQueue = {}
local RENDER_QUEUE_UNKNOWN_ALPHA_CLASS = "RENDER_QUEUE_UNKNOWN_ALPHA_CLASS"

local ALPHA_CLASSES = {
  [AlphaClassifier.OPAQUE] = true,
  [AlphaClassifier.CUTOUT] = true,
  [AlphaClassifier.TRANSLUCENT] = true,
  [AlphaClassifier.WIREFRAME] = true,
  [AlphaClassifier.MIXED] = true,
}

-- Validate the item's renderer-facing alpha class instead of inferring it from
-- material state. Queue classification is the authority for the pass an item
-- lands in; the renderer receives that selected class when drawing it.
---@param item table
---@return string
function RenderQueue.classifyAlphaClass(item)
  local mode = item.alphaClass
  if not ALPHA_CLASSES[mode] then
    Errors.raise(
      RENDER_QUEUE_UNKNOWN_ALPHA_CLASS,
      "render item has unknown alpha class " .. tostring(mode),
      { alphaClass = mode }
    )
  end
  return mode
end

-- Transform a world-space center into view space and return its Z distance
-- from the camera. The camera looks down -Z in view space, so objects in
-- front of the camera carry negative view-space Z and a more negative value
-- means farther away; sorting ascending therefore places far objects first.
local function viewSpaceZ(viewMatrix, x, y, z)
  local _, _, viewZ = Matrix4.transformPoint(viewMatrix, x, y, z)
  return viewZ
end

-- A full billboard is identity-oriented in view space. Its model-space center
-- therefore contributes directly along the view axes after component-wise
-- scaling, without resolving a camera-facing world matrix.
local function itemViewSpaceZ(item, viewMatrix)
  if item.billboardCenter == nil then
    local wx, wy, wz = Matrix4.transformPoint(item.transform, item.center[1], item.center[2], item.center[3])
    return viewSpaceZ(viewMatrix, wx, wy, wz)
  end
  assert(item.billboardScale, "billboard item requires billboardScale")
  local _, _, viewCenterZ =
    Matrix4.transformPoint(viewMatrix, item.billboardCenter[1], item.billboardCenter[2], item.billboardCenter[3])
  return viewCenterZ + item.center[3] * item.billboardScale[3]
end

local function clear(items)
  for i = #items, 1, -1 do
    items[i] = nil
  end
end

---@class RenderQueueScratch
---@field opaque table[]
---@field cutout table[]
---@field mixedOpaque table[]
---@field wireframe table[]
---@field blended table[]

-- Build into renderer-owned scratch storage. Parts are traversed in source
-- order and share one submission position sequence, including across part
-- boundaries. The scratch arrays retain their identities across calls.
-- Mixed items appear in both mixedOpaque and blended. Blended contains
-- decorated pass records, not original items.
---@param parts table[][]
---@param viewMatrix number[]
---@param scratch RenderQueueScratch
---@return RenderQueueScratch
function RenderQueue.buildInto(parts, viewMatrix, scratch)
  local opaque = scratch.opaque
  local cutout = scratch.cutout
  local mixedOpaque = scratch.mixedOpaque
  local wireframe = scratch.wireframe
  local blended = scratch.blended
  assert(opaque and cutout and mixedOpaque and wireframe and blended, "render queue scratch is incomplete")

  clear(opaque)
  clear(cutout)
  clear(mixedOpaque)
  clear(wireframe)

  local position = 0
  local blendedCount = 0
  for _, part in ipairs(parts) do
    for _, item in ipairs(part) do
      position = position + 1
      local mode = RenderQueue.classifyAlphaClass(item)

      if mode == AlphaClassifier.OPAQUE then
        opaque[#opaque + 1] = item
      elseif mode == AlphaClassifier.CUTOUT then
        cutout[#cutout + 1] = item
      elseif mode == AlphaClassifier.MIXED then
        mixedOpaque[#mixedOpaque + 1] = item

        blendedCount = blendedCount + 1
        local entry = blended[blendedCount] or {}
        entry.item = item
        entry.fragmentPass = AlphaClassifier.MIXED
        entry.viewZ = itemViewSpaceZ(item, viewMatrix)
        entry.position = position
        blended[blendedCount] = entry
      elseif mode == AlphaClassifier.TRANSLUCENT then
        blendedCount = blendedCount + 1
        local entry = blended[blendedCount] or {}
        entry.item = item
        entry.fragmentPass = AlphaClassifier.TRANSLUCENT
        entry.viewZ = itemViewSpaceZ(item, viewMatrix)
        entry.position = position
        blended[blendedCount] = entry
      else
        wireframe[#wireframe + 1] = item
      end
    end
  end

  for i = #blended, blendedCount + 1, -1 do
    blended[i] = nil
  end

  table.sort(blended, function(a, b)
    if a.viewZ ~= b.viewZ then
      return a.viewZ < b.viewZ
    end
    return a.position < b.position
  end)

  return scratch
end

return RenderQueue
