-- Compiles the separate HGSS static map-object model class used by books,
-- gates, and similar object events. These resources are self-contained NSBMDs
-- with embedded TEX0 data and do not use the mmodel billboard descriptor table.
-- The original loader is `ov01_021FD2EC` / NARC 103 in pokeheartgold.

local Errors = require("libs.rom.src.Errors")
local AlphaClassifier = require("romdump.src.digest.AlphaClassifier")
local MaterialCompiler = require("romdump.src.digest.MaterialCompiler")
local MeshCompiler = require("romdump.src.digest.MeshCompiler")
local DsPolygonAttr = require("romdump.src.digest.nitro.DsPolygonAttr")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")

local FieldActorStaticModel = {}

FieldActorStaticModel.COMPILER_VERSION = "field-actor-static-model-v1"

local function fail(code, message, context)
  Errors.raise(code, message, { context = context })
end

local function bounds(vertices)
  local minX, minY, minZ = math.huge, math.huge, math.huge
  local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
  for _, vertex in ipairs(vertices) do
    minX, maxX = math.min(minX, vertex.x), math.max(maxX, vertex.x)
    minY, maxY = math.min(minY, vertex.y), math.max(maxY, vertex.y)
    minZ, maxZ = math.min(minZ, vertex.z), math.max(maxZ, vertex.z)
  end
  return {
    width = maxX - minX,
    height = maxY - minY,
    depth = maxZ - minZ,
    center = { (minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2 },
  }
end

local function polygonRecord(raw)
  local polygon = DsPolygonAttr.decode(raw)
  return {
    polygonAttrRaw = polygon.polygonAttrRaw,
    polygonAlpha = polygon.polygonAlpha,
    polygonMode = polygon.polygonMode,
    polygonId = polygon.polygonId,
    lightMask = polygon.lightMask,
    cullMode = polygon.cullMode,
    translucentDepthWrite = polygon.translucentDepthWrite,
    depthEqual = polygon.depthEqual,
    farClipEnabled = polygon.farClipEnabled,
    oneDotEnabled = polygon.oneDotEnabled,
    fogEnabled = polygon.fogEnabled,
  }
end

local function packTextures(order)
  local width, height = 0, 0
  for _, entry in ipairs(order) do
    entry.x = width
    width = width + entry.texture.width
    height = math.max(height, entry.texture.height)
  end
  local rows = {}
  for y = 0, height - 1 do
    local row = {}
    for index, entry in ipairs(order) do
      local texture = entry.texture
      if y < texture.height then
        local stride = texture.width * 4
        row[index] = texture.pixels:sub(y * stride + 1, (y + 1) * stride)
      else
        row[index] = string.rep("\0", texture.width * 4)
      end
    end
    rows[y + 1] = table.concat(row)
  end
  return { width = width, height = height, pixels = table.concat(rows) }
end

function FieldActorStaticModel.compile(modelBytes, context, texturePack, textureArchive)
  local file = assert(Nsbmd.decode(modelBytes, context))
  local pack = texturePack or file.embeddedTextures
  if #file.models ~= 1 or not pack then
    fail(
      "FIELD_ACTOR_STATIC_MODEL_SHAPE_UNSUPPORTED",
      "static actor resource must contain one model and embedded textures",
      context
    )
  end
  local model = file.models[1]
  local batches = MeshCompiler.compile(model)

  local compiled =
    MaterialCompiler.compile(model.materials, pack, { context = { textureArchive = textureArchive or "embedded" } })
  if #compiled.unresolved > 0 then
    fail(
      "FIELD_ACTOR_STATIC_MODEL_TEXTURE_UNRESOLVED",
      "static actor model " .. model.name .. " has an unresolved texture binding",
      context
    )
  end
  local materialById = {}
  for _, material in ipairs(compiled.materials) do
    materialById[material.id] = material
  end
  local textureOrder, textureByKey = {}, {}
  for _, batch in ipairs(batches) do
    local material = materialById[batch.materialIndex]
    if not material then
      fail(
        "FIELD_ACTOR_STATIC_MODEL_TEXTURE_UNRESOLVED",
        "static actor model " .. model.name .. " has no material for a draw",
        context
      )
    end
    if material.texture and not textureByKey[material.texture] then
      local entry = { key = material.texture, texture = assert(compiled.textures[material.texture]) }
      textureByKey[material.texture] = entry
      textureOrder[#textureOrder + 1] = entry
    end
  end
  assert(#textureOrder > 0, "static actor model needs at least one textured draw")
  local atlas = packTextures(textureOrder)
  local parts = {}
  local allVertices = {}
  for _, batch in ipairs(batches) do
    local material = materialById[batch.materialIndex]
    local textureEntry = material.texture and textureByKey[material.texture] or nil
    for _, vertex in ipairs(batch.vertices) do
      if textureEntry then
        vertex.u = (textureEntry.x + vertex.u) / atlas.width
        vertex.v = vertex.v / atlas.height
      else
        vertex.u, vertex.v = 0, 0
      end
      allVertices[#allVertices + 1] = vertex
    end
    local polygon = polygonRecord(batch.polygonAttrRaw)
    local alphaClass = AlphaClassifier.classify(
      polygon.polygonAlpha,
      material.textureFormat or 0,
      textureEntry and textureEntry.texture.alphaUsage or nil
    )
    local partBounds = bounds(batch.vertices)
    parts[#parts + 1] = {
      textured = textureEntry ~= nil,
      alphaClass = alphaClass,
      polygon = polygon,
      geometry = {
        modelName = model.name,
        vertices = batch.vertices,
        indices = batch.indices,
        anchorTiles = { x = 0, y = 0, z = 0 },
        bounds = {
          width = partBounds.width,
          height = partBounds.height,
          depth = partBounds.depth,
        },
        center = partBounds.center,
      },
    }
  end
  local modelBounds = bounds(allVertices)
  return {
    atlas = {
      width = atlas.width,
      height = atlas.height,
      pixels = atlas.pixels,
      frameWidth = atlas.width,
      frameHeight = atlas.height,
    },
    render = {
      kind = "staticModel",
      frameWidth = atlas.width,
      frameHeight = atlas.height,
      frameCount = 1,
      parts = parts,
      bounds = {
        width = modelBounds.width,
        height = modelBounds.height,
        depth = modelBounds.depth,
      },
    },
  }
end

return FieldActorStaticModel
