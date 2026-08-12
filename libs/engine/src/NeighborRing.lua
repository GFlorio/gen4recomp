-- Loads the presentation-only neighbour ring from the derived cache into GPU
-- draws. The ring is planned and compiled upstream (libs/assets NeighborPlan +
-- MapAssetCompiler), which digests the eight surrounding matrix cells into
-- scene.neighbors -- one descriptor per drawn cell carrying its 32-tile offset,
-- terrain batches (content-addressed .g4mesh paths), and scene-form materials.
-- load() reads those assets through the shared GpuAssetPool (one persistent
-- Mesh per unique geometry path, one Image per unique texture/wrap sampler
-- state, deduplicated across cells), and bakes each cell's world offset into
-- the draw transform and sort center. Material wrap resolution lives in
-- SceneDescriptor; each geometry path's sort center is the pool mesh
-- entry's cached model-space center. All GPU construction happens here, once;
-- the pool releases every owned mesh/image. Load is transactional: the whole
-- build runs inside pool:transaction(), so a failure -- including a malformed
-- cell descriptor -- releases every GPU object the construction acquired.
-- Neighbours are additive: an empty descriptor list yields no draws and the
-- central scene is untouched.

local Matrix4 = require("libs.math.src.Matrix4")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")
local DsLighting = require("libs.engine.src.DsLighting")
local PolygonState = require("libs.assets.src.PolygonState")
local SceneDescriptor = require("libs.engine.src.SceneDescriptor")

local NeighborRing = {}

-- Material assembly: acquire each normalized material record's image
-- under its resolved sampler wrap. The wrap pair is part of the image
-- identity, so cells sharing a texture but sampling it differently get
-- independent configured images.
local function materialsById(list, pool)
  local byId = {}
  for id, record in pairs(SceneDescriptor.materials(list)) do
    byId[id] = {
      id = record.id,
      name = record.name,
      image = pool:imageFor(record.texture, record.wrap.x, record.wrap.y),
    }
  end
  return byId
end

-- Build the ring against an already-created pool, inside the transaction
-- load() opens. Raises on any failure; the transaction releases the pool in
-- that case. Draws carry no submission numbers: the final scene assembly
-- (SceneAssembly) orders every draw in source order, positionally. The
-- draw-state field set is the shared PolygonState schema; the defaults cover
-- cell records
-- that predate it (derived data never needs them; lightMask has no default
-- -- a missing mask must never mean "all lights").
local DRAW_STATE_DEFAULTS = {
  cullMode = "back",
  polygonMode = "modulation",
  polygonId = 0,
  translucentDepthWrite = false,
  depthEqual = false,
}
local function buildRing(pool, descriptors)
  -- One draw per (cell, batch), with the cell's 32-tile world offset baked into
  -- the transform and the sort center.
  local draws = {}
  for _, cell in ipairs(descriptors or {}) do
    local ox, oz = cell.offsetTilesX, cell.offsetTilesZ
    local transform = Matrix4.translate(ox, 0, oz)
    local materials = materialsById(cell.materials, pool)
    for _, batch in ipairs(cell.batches) do
      local entry = pool:meshFor(batch.geometry)
      local c = entry.center
      ---@type table<string, any>
      local draw = {
        mesh = entry.mesh,
        material = materials[batch.material],
        transform = transform,
        alphaClass = batch.alphaClass or "opaque",
        alphaCutoff = 0.5 / 255,
        center = { c[1] + ox, c[2], c[3] + oz },
      }
      for _, field in ipairs(PolygonState.FIELDS) do
        local value = batch[field]
        if field == "polygonAlpha" then
          draw[field] = value ~= nil and (value / DsLighting.RGB5_MAX) or 1.0
        else
          draw[field] = value or DRAW_STATE_DEFAULTS[field]
        end
      end
      draws[#draws + 1] = draw
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

-- Load the compiled neighbour ring into GPU draw items. `cacheFs` is a
-- CacheFs.forVersion; `descriptors` is scene.neighbors; `opts` passes through
-- to the asset pool (injectable graphics for headless tests). Returns
-- { draws, stats, release }. The whole build runs inside pool:transaction(),
-- so any failure -- including a malformed cell descriptor -- releases every
-- GPU object the construction acquired before the error propagates.
---@param cacheFs table
---@param descriptors table[]
---@param opts { graphics?: love.Graphics? }?
---@return table
function NeighborRing.load(cacheFs, descriptors, opts)
  local pool = GpuAssetPool.new(cacheFs, opts)
  return pool:transaction(function()
    return buildRing(pool, descriptors)
  end)
end

return NeighborRing
