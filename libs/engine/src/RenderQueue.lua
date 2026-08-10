-- Pure render-queue builder. Combines the flattened scene's draw items (map,
-- building, neighbour, and actor), partitions them into opaque / cutout /
-- translucent / wireframe passes, preserves submission order for
-- opaque/cutout/wireframe, and sorts translucent draws approximately
-- back-to-front in camera space using the item center and the view matrix.
-- The submission index is used as a deterministic tie-breaker -- assembly
-- (SceneAssembly) assigns it monotonically in desired source order, so the
-- queue never invents cross-group ordering. This is an explicit approximation
-- of DS auto sorting, not a claim of exact hardware ordering. Pure domain
-- module: no love, arithmetic only.
--
-- Queue construction validates its input contract and never mutates the
-- caller's draw records: only the four known alpha classes are accepted
-- (anything else -- including a missing class -- fails loudly instead of
-- defaulting to opaque), every item must carry a valid integer submission
-- index, and the translucent sort runs over local decorated sort entries so no
-- `_viewZ`-style field is written back onto the persistent items. The returned
-- queue holds the original item tables.

local Errors = require("libs.rom.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")

local RenderQueue = {}

local ALPHA_CLASSES = {
  opaque = true,
  cutout = true,
  translucent = true,
  wireframe = true,
}

local function isInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

-- Resolve the item's alpha class (item first, then its material's) and reject
-- anything outside the four known classes instead of defaulting to opaque.
local function classify(item)
  local mode = item.alphaClass or (item.material and item.material.alphaClass)
  if not ALPHA_CLASSES[mode] then
    Errors.raise(
      "RENDER_QUEUE_UNKNOWN_ALPHA_CLASS",
      "render item has unknown alpha class " .. tostring(mode),
      { alphaClass = mode }
    )
  end
  return mode
end

-- The submission index is the deterministic tie-breaker for equal-Z
-- translucent draws; an absent or non-integer index is malformed data, not a
-- silent 0.
local function requireSubmissionIndex(item)
  if not isInteger(item.submissionIndex) then
    Errors.raise(
      "RENDER_QUEUE_SUBMISSION_INVALID",
      "render item requires an integer submission index, got " .. tostring(item.submissionIndex),
      { submissionIndex = item.submissionIndex }
    )
  end
end

-- Transform a world-space center into view space and return its Z distance
-- from the camera. The camera looks down -Z in view space, so larger Z means
-- farther from the camera (more negative view-space Z). We return the view-space
-- Z so sorting ascending places far objects first.
local function viewSpaceZ(viewMatrix, center)
  local _, _, z = Matrix4.transformPoint(viewMatrix, center[1], center[2], center[3])
  return z
end

-- Build a draw queue from a flat list of items. Each item must expose:
--   alphaClass (or via its material), transform (4x4 array),
--   center ({x,y,z} in model space), submissionIndex (integer).
-- `viewMatrix` is the camera's 4x4 view matrix.
function RenderQueue.build(items, viewMatrix)
  local opaque, cutout, translucent, wireframe = {}, {}, {}, {}

  for _, item in ipairs(items) do
    local mode = classify(item)
    requireSubmissionIndex(item)
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

  -- Sort translucent back-to-front by view-space Z (farther first) over local
  -- decorated sort entries, so the caller's draw records never gain sort
  -- fields from repeated queue construction.
  local entries = {}
  for i, item in ipairs(translucent) do
    local wx, wy, wz = Matrix4.transformPoint(item.transform, item.center[1], item.center[2], item.center[3])
    entries[i] = { item = item, viewZ = viewSpaceZ(viewMatrix, { wx, wy, wz }) }
  end

  table.sort(entries, function(a, b)
    if a.viewZ ~= b.viewZ then
      return a.viewZ < b.viewZ
    end
    return a.item.submissionIndex < b.item.submissionIndex
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
