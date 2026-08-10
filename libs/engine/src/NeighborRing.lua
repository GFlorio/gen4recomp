-- Loads the presentation-only neighbour ring from the derived cache into GPU
-- draws. The ring is planned and compiled upstream (libs/assets NeighborPlan +
-- MapAssetCompiler), which digests the eight surrounding matrix cells into
-- scene.neighbors -- one descriptor per drawn cell carrying its 32-tile offset,
-- terrain batches (content-addressed .g4mesh paths), and scene-form materials.
-- load() reads those assets through the shared GpuAssetPool (one persistent
-- Mesh per unique geometry path, one Image per unique texture/wrap sampler
-- state, deduplicated across cells), and bakes each cell's world offset into
-- the draw transform and sort center. All GPU construction happens here, once;
-- the pool releases every owned mesh/image. Neighbours are additive: an empty
-- descriptor list yields no draws and the central scene is untouched.

local Matrix4 = require("libs.math.src.Matrix4")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")

local NeighborRing = {}

-- Index a descriptor's scene-form material list by id. The wrap pair is part
-- of the image identity, so cells sharing a texture but sampling it
-- differently get independent configured images.
local function materialsById(list, pool)
  local byId = {}
  for _, m in ipairs(list or {}) do
    local wrap = m.wrap or { x = "clamp", y = "clamp" }
    local d = m.diffuse or { r = 255, g = 255, b = 255, a = 255 }
    byId[m.id] = {
      id = m.id,
      name = m.name,
      image = pool:imageFor(m.texture, wrap.x, wrap.y),
      diffuse = { d.r / 255, d.g / 255, d.b / 255, d.a / 255 },
    }
  end
  return byId
end

local function modelCenter(verts)
  local minx, miny, minz = math.huge, math.huge, math.huge
  local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
  for _, v in ipairs(verts) do
    minx = math.min(minx, v[1])
    maxx = math.max(maxx, v[1])
    miny = math.min(miny, v[2])
    maxy = math.max(maxy, v[2])
    minz = math.min(minz, v[3])
    maxz = math.max(maxz, v[3])
  end
  return { (minx + maxx) / 2, (miny + maxy) / 2, (minz + maxz) / 2 }
end

-- Load the compiled neighbour ring into GPU draw items. `cacheFs` is a
-- CacheFs.forVersion; `descriptors` is scene.neighbors. Returns
-- { draws, stats, release }.
function NeighborRing.load(cacheFs, descriptors)
  local pool = GpuAssetPool.new(cacheFs)

  -- One draw per (cell, batch), with the cell's 32-tile world offset baked into
  -- the transform and the sort center.
  local draws = {}
  local submission = 200000 -- behind the diagnostic overlays' index space
  for _, cell in ipairs(descriptors or {}) do
    local ox, oz = cell.offsetTilesX, cell.offsetTilesZ
    local transform = Matrix4.translate(ox, 0, oz)
    local materials = materialsById(cell.materials, pool)
    for _, batch in ipairs(cell.batches) do
      local entry = pool:meshFor(batch.geometry)
      local c = modelCenter(entry.verts)
      submission = submission + 1
      draws[#draws + 1] = {
        mesh = entry.mesh,
        material = materials[batch.material],
        transform = transform,
        alphaClass = batch.alphaClass or "opaque",
        cullMode = batch.cullMode or "back",
        alphaCutoff = 0.5 / 255,
        polygonAlpha = batch.polygonAlpha ~= nil and (batch.polygonAlpha / 31) or 1.0,
        polygonMode = batch.polygonMode or "modulation",
        lightMask = batch.lightMask or 0,
        polygonId = batch.polygonId or 0,
        translucentDepthWrite = batch.translucentDepthWrite or false,
        depthEqual = batch.depthEqual or false,
        center = { c[1] + ox, c[2], c[3] + oz },
        submissionIndex = submission,
      }
    end
  end

  local ring = {
    draws = draws,
    stats = {
      cellCount = #(descriptors or {}),
      meshCount = #pool.meshes,
      textureCount = #pool.images,
    },
  }
  function ring:release()
    pool:release()
  end
  return ring
end

return NeighborRing
