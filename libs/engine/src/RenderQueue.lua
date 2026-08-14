-- Pure render-queue builder. Traverses ordered scene parts (map, building,
-- neighbour, and actor), partitions their draw items into opaque / cutout /
-- translucent / wireframe passes, preserves source order for
-- opaque/cutout/wireframe, and sorts translucent draws approximately
-- back-to-front in camera space using the item center and the view matrix.
-- The item's traversal position across ordered parts is the deterministic
-- tie-breaker for equal-depth translucent draws, so the queue never invents
-- cross-group ordering. This
-- is an explicit approximation of DS auto sorting, not a claim of exact
-- hardware ordering. Pure domain module: no love, arithmetic only.
--
-- Queue construction validates its input contract and never mutates the
-- caller's draw records: only the four known alpha classes are accepted
-- (anything else -- including a missing class -- fails loudly instead of
-- defaulting to opaque), and the translucent sort runs over local decorated
-- sort entries so no `_viewZ`-style field is written back onto the persistent
-- items. The returned queue holds the original item tables.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local Matrix4 = require("libs.math.src.Matrix4")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")

local RenderQueue = {}

local ALPHA_CLASSES = {
  [AlphaClassifier.OPAQUE] = true,
  [AlphaClassifier.CUTOUT] = true,
  [AlphaClassifier.TRANSLUCENT] = true,
  [AlphaClassifier.WIREFRAME] = true,
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
      FieldErrors.RENDER_QUEUE_UNKNOWN_ALPHA_CLASS,
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

local function clear(items)
  for i = #items, 1, -1 do
    items[i] = nil
  end
end

---@class RenderQueueScratch
---@field opaque table[]
---@field cutout table[]
---@field translucent table[]
---@field wireframe table[]
---@field translucentEntries table[]

-- Build into renderer-owned scratch storage. Parts are traversed in source
-- order and share one submission position sequence, including across part
-- boundaries. The scratch arrays retain their identities across calls.
---@param parts table[][]
---@param viewMatrix number[]
---@param scratch RenderQueueScratch
---@return RenderQueueScratch
function RenderQueue.buildInto(parts, viewMatrix, scratch)
  local opaque = scratch.opaque
  local cutout = scratch.cutout
  local translucent = scratch.translucent
  local wireframe = scratch.wireframe
  local entries = scratch.translucentEntries
  assert(opaque and cutout and translucent and wireframe and entries, "render queue scratch is incomplete")

  clear(opaque)
  clear(cutout)
  clear(translucent)
  clear(wireframe)

  local position = 0
  local entryCount = 0
  for _, part in ipairs(parts) do
    for _, item in ipairs(part) do
      position = position + 1
      local mode = RenderQueue.classifyAlphaClass(item)
      if mode == AlphaClassifier.TRANSLUCENT then
        entryCount = entryCount + 1
        local entry = entries[entryCount] or {}
        local wx, wy, wz = Matrix4.transformPoint(item.transform, item.center[1], item.center[2], item.center[3])
        entry.item = item
        entry.viewZ = viewSpaceZ(viewMatrix, wx, wy, wz)
        entry.position = position
        entries[entryCount] = entry
      elseif mode == AlphaClassifier.CUTOUT then
        cutout[#cutout + 1] = item
      elseif mode == AlphaClassifier.WIREFRAME then
        wireframe[#wireframe + 1] = item
      else
        opaque[#opaque + 1] = item
      end
    end
  end

  for i = #entries, entryCount + 1, -1 do
    entries[i] = nil
  end

  table.sort(entries, function(a, b)
    if a.viewZ ~= b.viewZ then
      return a.viewZ < b.viewZ
    end
    return a.position < b.position
  end)

  for i, entry in ipairs(entries) do
    translucent[i] = entry.item
  end

  return scratch
end

return RenderQueue
