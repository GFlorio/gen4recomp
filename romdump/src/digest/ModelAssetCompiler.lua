-- The one model-compilation core producing content-addressed batches, meshes,
-- and textures for one decoded model bound to one texture pack. MapAssetCompiler
-- (map and placed-building models) and NeighborChunkCompiler (terrain models)
-- both call compileModel; each caller owns its bundle accumulators and
-- continues from the returned batches/materials/unresolved records. The batch
-- record's polygon draw state rides the shared PolygonState schema and the
-- transform-mode vocabulary comes from PoseContract, so the serialized model
-- descriptor has exactly one authority.

local MeshCompiler = require("romdump.src.digest.MeshCompiler")
local MaterialCompiler = require("romdump.src.digest.MaterialCompiler")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local DsPolygonAttr = require("romdump.src.digest.nitro.DsPolygonAttr")
local MeshWriter = require("libs.assets.src.MeshWriter")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local PoseContract = require("libs.assets.src.PoseContract")
local PolygonState = require("libs.assets.src.PolygonState")
local TextureMatrixState = require("romdump.src.digest.TextureMatrixState")

local ModelAssetCompiler = {}

-- Convert MaterialCompiler records (texture = sha1 key) into scene material
-- records (texture = cache-relative PNG path). Polygon state (alpha class,
-- cull mode, polygon alpha/mode) lives on the batch, not the material.
-- `terrainStateById` supplies the shared decoded-material texture-matrix
-- fields (texWidth/texHeight/texMtxMode and the normalized static srt) for
-- terrain scene materials; building models compile without it.
local function sceneMaterials(records, terrainStateById)
  local out = {}
  for _, m in ipairs(records) do
    local record = {
      id = m.id,
      name = m.name,
      texture = m.texture and MapAssetCache.texturePath(m.texture) or nil,
      textureFormat = m.textureFormat,
      wrap = m.wrap,
      flip = m.flip,
      diffuse = m.diffuse,
    }
    local terrain = terrainStateById and terrainStateById[m.id]
    if terrain then
      record.texWidth = terrain.texWidth
      record.texHeight = terrain.texHeight
      record.texMtxMode = terrain.texMtxMode
      record.srt = terrain.srt
    end
    out[#out + 1] = record
  end
  return out
end

-- Compile one model into batches; append meshes/textures to the shared bundle
-- accumulators; return { batches (scene refs), materials, unresolved } -- the
-- last being the materials whose names the bound pack does not define, tagged
-- with the model they came from so a caller can report them. When the caller
-- passes a map-scoped terrain-animation compiler in
-- `context.terrainAnimationCompiler` (the option's presence selects
-- annotation, not the role), every material whose texture name an fldtanime
-- record names gets a textureSwap record and its alternate frames join the
-- shared texture accumulator.
local function compileModel(model, texturePack, meshes, textures, context)
  local mat = MaterialCompiler.compile(model.materials, texturePack, { context = context })
  for sha1, tex in pairs(mat.textures) do
    textures[sha1] = tex
  end

  local unresolved = {}
  for _, entry in ipairs(mat.unresolved) do
    unresolved[#unresolved + 1] = {
      role = context.role,
      modelArchive = context.modelArchive,
      modelMemberId = context.modelMemberId,
      modelName = context.modelName,
      material = entry.material,
      kind = entry.kind,
      name = entry.name,
      source = entry.source,
    }
  end

  -- Per-material texture info needed for batch classification and UV normalization.
  local matInfoById = {}
  for _, m in ipairs(mat.materials) do
    matInfoById[m.id] = {
      texWidth = m.texWidth,
      texHeight = m.texHeight,
      textureFormat = m.textureFormat or 0,
      alphaUsage = m.texture and textures[m.texture] and textures[m.texture].alphaUsage or nil,
    }
  end

  -- Terrain scene materials (map and neighbor roles) carry the decoded
  -- texture-matrix fields, the same conversion the dynamic model base
  -- materials use; placed-building models never gain them.
  local terrainStateById
  if context.role == "map" or context.role == "neighbor" then
    terrainStateById = {}
    for _, mat in ipairs(model.materials) do
      terrainStateById[mat.index] = TextureMatrixState.fromMaterial(mat, model.info.texMtxMode)
    end
  end

  local materials = sceneMaterials(mat.materials, terrainStateById)
  if context.terrainAnimationCompiler then
    for i, m in ipairs(mat.materials) do
      -- A matched record yields a textureSwap record; an unmatched material
      -- or one that failed texture binding leaves the field omitted.
      local swap = context.terrainAnimationCompiler:annotateMaterial(model.materials[i], m, texturePack, textures)
      if swap then
        materials[i].textureSwap = swap
      end
    end
  end

  local batches = {}
  for _, batch in ipairs(MeshCompiler.compile(model)) do
    local info = matInfoById[batch.materialIndex]
    if info and info.texWidth then
      for _, vtx in ipairs(batch.vertices) do
        vtx.u = vtx.u / info.texWidth
        vtx.v = vtx.v / info.texHeight
      end
    end

    local poly = DsPolygonAttr.decode(batch.polygonAttrRaw)
    if poly.cullMode ~= "all" then
      local fmt = info and info.textureFormat or 0
      local alphaClass = AlphaClassifier.classify(poly.polygonAlpha, fmt, info and info.alphaUsage or nil)
      local sha1 = Hashing.sha1hex(MeshWriter.encode(batch))
      meshes[sha1] = batch
      local record = {
        geometry = MapAssetCache.geometryPath(sha1),
        material = batch.materialIndex,
        node = batch.nodeIndex,
        -- A billboard batch's geometry is in billboard-local space and its
        -- matrix is only resolvable against a live camera; the runtime rebuilds
        -- it from baseTransform every frame. The static mode is the default and
        -- is left off, so it does not repeat on every batch of every scene.
        transformMode = batch.transformMode ~= PoseContract.STATIC and batch.transformMode or nil,
        baseTransform = batch.baseTransform,
        alphaClass = alphaClass,
      }
      -- The shared polygon draw-state field set (PolygonState.FIELDS).
      for _, field in ipairs(PolygonState.FIELDS) do
        record[field] = poly[field]
      end
      -- The static-only extras stay outside the shared draw-state schema:
      -- they are authoring metadata the runtime does not consume.
      record.farClipEnabled = poly.farClipEnabled
      record.oneDotEnabled = poly.oneDotEnabled
      record.fogEnabled = poly.fogEnabled
      batches[#batches + 1] = record
    end
  end
  return { batches = batches, materials = materials, unresolved = unresolved }
end

ModelAssetCompiler.compileModel = compileModel

return ModelAssetCompiler
