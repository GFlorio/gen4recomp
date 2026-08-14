-- Loads the presentation-only neighbour ring from the derived cache into GPU
-- draws. The ring is planned and compiled upstream (libs/assets NeighborPlan +
-- MapAssetCompiler), which digests the eight surrounding matrix cells into
-- scene.neighbors -- one descriptor per drawn cell carrying its 32-tile offset,
-- terrain batches (content-addressed .g4mesh paths), and scene-form materials.
-- load() reads those assets through the shared GpuAssetPool (one persistent
-- Mesh per unique geometry path, one Image per unique texture/wrap sampler
-- state, deduplicated across cells), and bakes each cell's world offset into
-- the draw transform while retaining each mesh's model-space sort center.
-- Material wrap resolution lives in
-- SceneDescriptor; each geometry path's sort center is the pool mesh
-- entry's cached model-space center. All GPU construction happens here, once;
-- the pool releases every owned mesh/image. Load is transactional: the whole
-- build runs inside pool:build(), so a failure -- including a malformed
-- cell descriptor or a terrain-animator construction failure -- releases
-- every GPU object the construction acquired.
-- Terrain animation spans the whole ring: one TerrainMaterialAnimator over
-- every cell's { record, runtime } bindings (the original descriptor records
-- are referenced directly -- cell material ids repeat per cell but nothing
-- needs a global id space) plays the central scene's area texture-SRT clip
-- -- passed as `opts.textureSrt`, the central scene owns the clip -- and
-- the shared per-name texture-swap clocks with one stepIndex/ticksInStep
-- pair per animation name across all cells, all step images acquired inside
-- the ring's own pool build. ring:updateAnimated() advances that one
-- animator; empty neighbours keep it a safe no-op. Neighbours are additive:
-- an empty descriptor list yields no draws and the central scene is
-- untouched.

local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local SceneDescriptor = require("libs.engine.src.SceneDescriptor")
local TerrainMaterialAnimator = require("libs.engine.src.TerrainMaterialAnimator")

local NeighborRing = {}

-- Material assembly: acquire each normalized material record's image
-- under its resolved sampler wrap. The wrap pair is part of the image
-- identity, so cells sharing a texture but sampling it differently get
-- independent configured images. The terrain animator initializes every
-- material's texMatrix at construction.
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

-- Build the ring against an already-created pool, inside the build
-- wrapper load() opens. Raises on any failure; the wrapper releases the pool
-- in that case. Draws carry no submission numbers: the final scene assembly
-- queue traversal orders every part and draw in source order, positionally. The
-- draw-state field set is the shared PolygonState schema the compiler emits on every batch
-- (lightMask included), with polygonAlpha normalized to the renderer's 0..1
-- unit. `clip` is the central scene's compiled texture-SRT clip (or false),
-- owned by the central scene: the ring never selects a clip per neighbour.
local function buildRing(pool, descriptors, clip)
  -- One draw per (cell, batch), with the cell's 32-tile world offset baked into
  -- the transform only -- the mesh center stays in model space for queue
  -- sorting -- and one { record, runtime } binding per source material: the
  -- original descriptor records are immutable and are referenced directly,
  -- so no synthetic id space is needed.
  local draws = {}
  local bindings = {}
  for _, cell in ipairs(descriptors) do
    local ox, oz = cell.offsetTilesX, cell.offsetTilesZ
    local transform = Matrix4.translate(ox, 0, oz)
    local materials = materialsById(cell.materials, pool)
    for _, record in ipairs(cell.materials) do
      bindings[#bindings + 1] = {
        record = record,
        runtime = assert(
          materials[record.id],
          "no runtime material table for neighbor material id " .. tostring(record.id)
        ),
      }
    end
    for _, batch in ipairs(cell.batches) do
      local entry = pool:meshFor(batch.geometry)
      local c = entry.center
      local draw = {
        cullMode = batch.cullMode,
        polygonMode = batch.polygonMode,
        polygonId = batch.polygonId,
        translucentDepthWrite = batch.translucentDepthWrite,
        depthEqual = batch.depthEqual,
        lightMask = batch.lightMask,
        polygonAlpha = batch.polygonAlpha / FixedPoint.RGB5_MAX,
        alphaClass = batch.alphaClass,
      }
      draw.mesh = entry.mesh
      draw.material = materials[batch.material]
      draw.transform = transform
      draw.alphaCutoff = AlphaClassifier.CUTOUT_EPSILON
      draw.center = c
      draws[#draws + 1] = draw
    end
  end

  -- One terrain animator across every cell, constructed unconditionally: all
  -- cells share the area SRT player and one stepIndex/ticksInStep pair per
  -- texture-swap name, every step image is acquired inside this build
  -- (deduplicated per path/wrap through the pool) before the transaction
  -- commits, and construction initializes every cell material's static
  -- texMatrix. ring:updateAnimated() stays a safe no-op on empty rings.
  local terrainAnimator = TerrainMaterialAnimator.new(bindings, clip or false, function(path, wrapX, wrapY)
    return pool:imageFor(path, wrapX, wrapY)
  end)

  local ring = {
    draws = draws,
    stats = {
      cellCount = #descriptors,
      meshCount = #pool.meshes,
      textureCount = #pool.images,
    },
  }
  function ring:updateAnimated()
    terrainAnimator:updateFixed()
  end
  function ring:release()
    pool:release()
  end
  return ring
end

-- Load the compiled neighbour ring into GPU draw items. `cacheFs` is a
-- CacheFs.forVersion; `descriptors` is scene.neighbors; `opts` passes through
-- to the asset pool (injectable graphics for headless tests), and
-- `opts.textureSrt` carries the central scene's compiled texture-SRT clip
-- (false/nil = no area animation). Returns { draws, stats, updateAnimated,
-- release }. The whole build runs inside pool:build(), so any failure --
-- including a malformed cell descriptor -- releases every GPU object the
-- construction acquired before the error propagates.
---@param cacheFs table
---@param descriptors table[]
---@param opts { graphics?: love.Graphics?, textureSrt?: table|false }?
---@return table
function NeighborRing.load(cacheFs, descriptors, opts)
  opts = opts or {}
  local pool = GpuAssetPool.new(cacheFs, opts)
  return pool:build(function()
    return buildRing(pool, descriptors, opts.textureSrt)
  end)
end

return NeighborRing
