-- Pure render-queue builder. Combines map, building, and overlay draw items,
-- partitions them into opaque / cutout / translucent / wireframe passes,
-- preserves submission order for opaque/cutout/wireframe, and sorts translucent
-- draws approximately back-to-front in camera space using the item center and
-- the view matrix. The submission index is used as a deterministic tie-breaker.
-- This is an explicit approximation of DS auto sorting, not a claim of exact
-- hardware ordering. Pure domain module: no love, arithmetic only.

local Matrix4 = require("libs.engine.src.Matrix4")

local RenderQueue = {}

local function classify(item)
  return item.alphaClass or (item.material and item.material.alphaClass) or "opaque"
end

-- Transform a world-space center into view space and return its Z distance
-- from the camera. The camera looks down -Z in view space, so larger Z means
-- farther from the camera (more negative view-space Z). We return the view-space
-- Z so sorting ascending places far objects first.
local function viewSpaceZ(viewMatrix, center)
  return Matrix4.transformPoint(viewMatrix, center[1], center[2], center[3])
end

-- Build a draw queue from a flat list of items. Each item must expose:
--   alphaClass, transform (4x4 array), center ({x,y,z} in model space),
--   submissionIndex (int).
-- `viewMatrix` is the camera's 4x4 view matrix.
function RenderQueue.build(items, viewMatrix)
  local opaque, cutout, translucent, wireframe = {}, {}, {}, {}

  for i, item in ipairs(items) do
    local mode = classify(item)
    if mode == "translucent" then
      translucent[#translucent + 1] = item
    elseif mode == "cutout" then
      cutout[#cutout + 1] = item
    elseif mode == "wireframe" then
      wireframe[#wireframe + 1] = item
    else
      opaque[#opaque + 1] = item
    end
  end

  -- Sort translucent back-to-front by view-space Z (farther first).
  for _, item in ipairs(translucent) do
    local wx, wy, wz = Matrix4.transformPoint(item.transform, item.center[1], item.center[2], item.center[3])
    local _, _, vz = viewSpaceZ(viewMatrix, { wx, wy, wz })
    item._viewZ = vz
  end

  table.sort(translucent, function(a, b)
    if a._viewZ ~= b._viewZ then return a._viewZ < b._viewZ end
    return (a.submissionIndex or 0) < (b.submissionIndex or 0)
  end)

  return {
    opaque = opaque,
    cutout = cutout,
    translucent = translucent,
    wireframe = wireframe,
  }
end

return RenderQueue
