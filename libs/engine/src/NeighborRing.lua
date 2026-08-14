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
-- build runs inside pool:build(), so a failure -- including a malformed
-- cell descriptor or a terrain-animator construction failure -- releases
-- every GPU object the construction acquired.
-- Terrain animation spans the whole ring: one TerrainMaterialAnimator over
-- every cell's runtime material tables (cell material ids repeat per cell, so
-- each record is re-keyed into the animator's single id space) plays the
-- central scene's area texture-SRT clip -- passed as `opts.textureSrt`, the
-- central scene owns the clip -- and the shared per-name texture-swap clocks
-- with one cursor per animation name across all cells, all frames acquired
-- inside the ring's own pool build. ring:updateAnimated() advances that one
-- animator; empty neighbours, cells without animation inputs, and a missing
-- clip keep it a safe no-op. Neighbours are additive: an empty descriptor
-- list yields no draws and the central scene is untouched.

local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local SceneDescriptor = require("libs.engine.src.SceneDescriptor")
local TerrainMaterialAnimator = require("libs.engine.src.TerrainMaterialAnimator")

local NeighborRing = {}

-- The identity UV-transform matrix scene-form materials start with (they
-- carry no texture-SRT until the terrain animator replaces the matrix of a
-- ring that has animation inputs): the renderer reads the material's
-- texMatrix directly.
local IDENTITY_TEX_MATRIX = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

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
      texMatrix = IDENTITY_TEX_MATRIX,
    }
  end
  return byId
end

-- Build the ring against an already-created pool, inside the build
-- wrapper load() opens. Raises on any failure; the wrapper releases the pool
-- in that case. Draws carry no submission numbers: the final scene assembly
-- (SceneAssembly) orders every draw in source order, positionally. The
-- draw-state field set is the shared PolygonState schema the compiler emits on every batch
-- (lightMask included), with polygonAlpha normalized to the renderer's 0..1
-- unit. `clip` is the central scene's compiled texture-SRT clip (or false),
-- owned by the central scene: the ring never selects a clip per neighbour.
local function buildRing(pool, descriptors, clip)
  -- One draw per (cell, batch), with the cell's 32-tile world offset baked into
  -- the transform and the sort center. Cell material ids repeat per cell, so
  -- the animator's record list re-keys each record into one flat id space
  -- while the per-cell runtime tables stay keyed by their own ids.
  local draws = {}
  local terrainRecords = {}
  local terrainMaterials = {}
  for _, cell in ipairs(descriptors) do
    local ox, oz = cell.offsetTilesX, cell.offsetTilesZ
    local transform = Matrix4.translate(ox, 0, oz)
    local materials = materialsById(cell.materials, pool)
    for _, record in ipairs(cell.materials) do
      local id = #terrainRecords
      terrainRecords[#terrainRecords + 1] = {
        id = id,
        name = record.name,
        texture = record.texture,
        wrap = record.wrap,
        texWidth = record.texWidth,
        texHeight = record.texHeight,
        texMtxMode = record.texMtxMode,
        srt = record.srt,
        textureSwap = record.textureSwap,
      }
      terrainMaterials[id] = materials[record.id]
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
      draw.center = { c[1] + ox, c[2], c[3] + oz }
      draws[#draws + 1] = draw
    end
  end

  -- One terrain animator across every cell: all cells share the area SRT
  -- player and one cursor/counter per texture-swap name, and every frame
  -- image is acquired inside this build (deduplicated per path/wrap through
  -- the pool) before the transaction commits. A ring with no animation input
  -- gets no animator; ring:updateAnimated() stays a safe no-op.
  local terrainAnimator
  if clip or SceneDescriptor.hasTextureSwap(terrainRecords) then
    terrainAnimator = TerrainMaterialAnimator.new(
      terrainRecords,
      terrainMaterials,
      clip or false,
      function(path, wrapX, wrapY)
        return pool:imageFor(path, wrapX, wrapY)
      end
    )
  end

  local ring = {
    draws = draws,
    stats = {
      cellCount = #descriptors,
      meshCount = #pool.meshes,
      textureCount = #pool.images,
    },
  }
  function ring:updateAnimated()
    if terrainAnimator then
      terrainAnimator:updateFixed()
    end
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
