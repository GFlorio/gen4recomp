-- Pure render-queue builder. Combines the flattened scene's draw items (map,
-- building, neighbour, and actor), partitions them into opaque / cutout /
-- translucent / wireframe passes, preserves flat-list order for
-- opaque/cutout/wireframe, and sorts translucent draws approximately
-- back-to-front in camera space using the item center and the view matrix.
-- The item's position in the flat scene list is the deterministic tie-breaker
-- for equal-depth translucent draws: SceneAssembly concatenates parts in
-- desired source order, so the queue never invents cross-group ordering. This
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

-- Resolve the item's effective alpha class (item first, then its material's)
-- and reject anything outside the four known classes instead of defaulting to
-- opaque. Queue classification and the renderer's shader setup share this one
-- function so the pass an item lands in and the shader mode it draws with can
-- never disagree.
---@param item table
---@return string
function RenderQueue.effectiveAlphaClass(item)
  local mode = item.alphaClass or (item.material and item.material.alphaClass)
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
local function viewSpaceZ(viewMatrix, center)
  local _, _, z = Matrix4.transformPoint(viewMatrix, center[1], center[2], center[3])
  return z
end

-- Build a draw queue from a flat list of items. Each item must expose:
--   alphaClass (or via its material), transform (4x4 array),
--   center ({x,y,z} in model space).
-- `viewMatrix` is the camera's 4x4 view matrix. The item's position in the
-- flat list is the deterministic tie-breaker for equal-depth translucent
-- draws (the assembly's submission order).
function RenderQueue.build(items, viewMatrix)
  local opaque, cutout, translucent, wireframe = {}, {}, {}, {}

  -- Sort entries for the translucent pass: local decorated entries carrying
  -- the view-space Z and the item's flat-list position (the deterministic
  -- tie-breaker), so the caller's draw records never gain sort fields from
  -- repeated queue construction.
  local entries = {}
  for position, item in ipairs(items) do
    local mode = RenderQueue.effectiveAlphaClass(item)
    if mode == AlphaClassifier.TRANSLUCENT then
      translucent[#translucent + 1] = item
      local wx, wy, wz = Matrix4.transformPoint(item.transform, item.center[1], item.center[2], item.center[3])
      entries[#entries + 1] = { item = item, viewZ = viewSpaceZ(viewMatrix, { wx, wy, wz }), position = position }
    elseif mode == AlphaClassifier.CUTOUT then
      cutout[#cutout + 1] = item
    elseif mode == AlphaClassifier.WIREFRAME then
      wireframe[#wireframe + 1] = item
    else
      opaque[#opaque + 1] = item
    end
  end

  -- Sort translucent back-to-front by view-space Z (farther first); equal-Z
  -- ties break by flat-list position, the assembly's submission order.
  table.sort(entries, function(a, b)
    if a.viewZ ~= b.viewZ then
      return a.viewZ < b.viewZ
    end
    return a.position < b.position
  end)

  for i, entry in ipairs(entries) do
    translucent[i] = entry.item
  end

  return {
    opaque = opaque,
    cutout = cutout,
    translucent = translucent,
    wireframe = wireframe,
  }
end

return RenderQueue
