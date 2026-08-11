-- Shared model-compilation core producing content-addressed batches, meshes,
-- and textures for one decoded model bound to one texture pack. Used by both
-- MapAssetCompiler (map and placed-building models) and NeighborChunkCompiler
-- (terrain models); each caller owns its bundle accumulators and continues
-- from the returned batches/materials/unresolved records.

local MeshCompiler = require("romdump.src.digest.MeshCompiler")
local MaterialCompiler = require("romdump.src.digest.MaterialCompiler")
local AlphaClassifier = require("romdump.src.digest.AlphaClassifier")
local DsPolygonAttr = require("romdump.src.digest.nitro.DsPolygonAttr")
local MeshWriter = require("libs.assets.src.MeshWriter")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local ModelAssetCompiler = {}

-- Convert MaterialCompiler records (texture = sha1 key) into scene material
-- records (texture = cache-relative PNG path). Polygon state (alpha class,
-- cull mode, polygon alpha/mode) lives on the batch, not the material.
local function sceneMaterials(records)
  local out = {}
  for _, m in ipairs(records) do
    out[#out + 1] = {
      id = m.id,
      name = m.name,
      texture = m.texture and MapAssetCache.texturePath(m.texture) or nil,
      textureFormat = m.textureFormat,
      wrap = m.wrap,
      flip = m.flip,
      diffuse = m.diffuse,
    }
  end
  return out
end

-- Compile one model into batches; append meshes/textures to the shared bundle
-- accumulators; return { batches (scene refs), materials, unresolved } -- the
-- last being the materials whose names the bound pack does not define, tagged
-- with the model they came from so a caller can report them.
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
      batches[#batches + 1] = {
        geometry = MapAssetCache.geometryPath(sha1),
        material = batch.materialIndex,
        node = batch.nodeIndex,
        -- A billboard batch's geometry is in billboard-local space and its
        -- matrix is only resolvable against a live camera; the runtime rebuilds
        -- it from baseTransform every frame. "static" is the default and is left
        -- off, so it does not repeat on every batch of every scene.
        transformMode = batch.transformMode ~= "static" and batch.transformMode or nil,
        baseTransform = batch.baseTransform,
        alphaClass = alphaClass,
        cullMode = poly.cullMode,
        polygonAlpha = poly.polygonAlpha,
        polygonMode = poly.polygonMode,
        lightMask = poly.lightMask,
        polygonId = poly.polygonId,
        translucentDepthWrite = poly.translucentDepthWrite,
        depthEqual = poly.depthEqual,
        farClipEnabled = poly.farClipEnabled,
        oneDotEnabled = poly.oneDotEnabled,
        fogEnabled = poly.fogEnabled,
      }
    end
  end
  return { batches = batches, materials = sceneMaterials(mat.materials), unresolved = unresolved }
end

ModelAssetCompiler.compileModel = compileModel

return ModelAssetCompiler
