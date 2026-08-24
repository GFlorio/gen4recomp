-- Compiles HGSS default field-effect renderer 3: field_static_models member
-- 85. Nitro decoding ends here; the runtime receives only normalized model
-- data and content-addressed mesh/texture references.

local Errors = require("libs.errors.src.Errors")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local ModelAssetCompiler = require("romdump.src.digest.ModelAssetCompiler")
local ModelAsset = require("libs.assets.src.ModelAsset")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local Hashing = require("romdump.src.digest.Hashing")

local Compiler = {}
local function member(narc, memberId)
  if memberId < 0 or memberId >= narc:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "field_static_models member 85 is unavailable", {
      archive = "field_static_models",
      memberId = memberId,
      count = narc:memberCount(),
    })
  end
  return assert(narc:readMember(memberId))
end

function Compiler.compile(romFs, hashLua)
  assert(romFs and romFs.openNarc, "field-effect compiler requires RomFs")
  hashLua = hashLua or Hashing.hashLua
  local narc = assert(romFs:openNarc("field_static_models"))
  local bytes = member(narc, 85)
  local decoded =
    assert(Nsbmd.decode(bytes, { alias = "field_static_models", memberId = 85, section = "warp-entrance-effect" }))
  local model = decoded.models[1]
  if not model or not decoded.embeddedTextures then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect member 85 has no decodable model textures", {
      archive = "field_static_models",
      memberId = 85,
    })
  end
  local embeddedTextures = assert(decoded.embeddedTextures)
  local meshes, textures = {}, {}
  local compiled = ModelAssetCompiler.compileModel(model, embeddedTextures, meshes, textures, {
    role = "field-effect",
    modelArchive = "field_static_models",
    modelMemberId = 85,
    modelName = model.name,
    textureArchive = "field_static_models",
    textureMemberId = 85,
  })
  if #compiled.unresolved > 0 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect member 85 has unresolved materials", {
      archive = "field_static_models",
      memberId = 85,
      unresolved = compiled.unresolved,
    })
  end
  local descriptor = {
    schema = ModelAsset.SCHEMA,
    key = "field-effect:warp-entrance",
    kind = "static",
    batches = compiled.batches,
    materials = compiled.materials,
  }
  for _, batch in ipairs(descriptor.batches) do
    local sha1 = assert(batch.geometry:match("/([^/]+)%.g4mesh$"), "compiled field-effect geometry path is malformed")
    batch.geometry = FieldEffectAssetCache.geometryPath(sha1)
  end
  for _, material in ipairs(descriptor.materials) do
    if material.texture then
      local sha1 = assert(material.texture:match("/([^/]+)%.png$"), "compiled field-effect texture path is malformed")
      material.texture = FieldEffectAssetCache.texturePath(sha1)
    end
  end
  local valid, err = pcall(ModelAsset.validate, descriptor)
  if not valid then
    error(err, 0)
  end
  local depHash = hashLua({ memberSha1 = Hashing.sha1hex(bytes), model = descriptor })
  return {
    model = descriptor,
    meshes = meshes,
    textures = textures,
    marker = FieldEffectAssetCache.marker(romFs:metadata().sha1, depHash),
  }
end

return Compiler
