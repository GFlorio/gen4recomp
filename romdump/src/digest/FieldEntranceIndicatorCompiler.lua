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

local function animation(members, duration)
  local frames = {}
  for _, memberId in ipairs(members) do
    frames[#frames + 1] = { memberId = memberId, duration = duration, values = { 0 } }
  end
  return {
    schema = "g4-field-effect-animation-v1",
    sourceMembers = members,
    frames = frames,
  }
end
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

local function compileModel(narc, memberId, key, section, role)
  local bytes = member(narc, memberId)
  local decoded = assert(Nsbmd.decode(bytes, {
    alias = "field_static_models",
    memberId = memberId,
    section = section,
  }))
  local model = decoded.models[1]
  if not model or not decoded.embeddedTextures then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect model has no decodable model textures", {
      archive = "field_static_models",
      memberId = memberId,
    })
  end
  local meshes, textures = {}, {}
  local compiled = ModelAssetCompiler.compileModel(model, decoded.embeddedTextures, meshes, textures, {
    role = role,
    modelArchive = "field_static_models",
    modelMemberId = memberId,
    modelName = model.name,
    textureArchive = "field_static_models",
    textureMemberId = memberId,
  })
  if #compiled.unresolved > 0 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect model has unresolved materials", {
      archive = "field_static_models",
      memberId = memberId,
      unresolved = compiled.unresolved,
    })
  end
  local descriptor = {
    schema = ModelAsset.SCHEMA,
    key = key,
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
  ModelAsset.validate(descriptor)
  return descriptor, meshes, textures, Hashing.sha1hex(bytes)
end

function Compiler.compile(romFs, hashLua)
  assert(romFs and romFs.openNarc, "field-effect compiler requires RomFs")
  hashLua = hashLua or Hashing.hashLua
  local narc = assert(romFs:openNarc("field_static_models"))
  local model, meshes, textures, warpSha =
    compileModel(narc, 85, "field-effect:warp-entrance", "warp-entrance-effect", "field-effect")
  local tall, tallMeshes, tallTextures, tallSha =
    compileModel(narc, 126, "field-effect:tall-grass", "tall-grass-renderer-8", "field-effect-grass")
  local veryTall, veryTallMeshes, veryTallTextures, veryTallSha =
    compileModel(narc, 122, "field-effect:very-tall-grass", "very-tall-grass-renderer-12", "field-effect-grass")
  for sha1, mesh in pairs(tallMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(tallTextures) do
    textures[sha1] = texture
  end
  for sha1, mesh in pairs(veryTallMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(veryTallTextures) do
    textures[sha1] = texture
  end
  local effects = {
    warp_entrance = { model = model, lifetime = 1 },
    tall_grass = {
      model = tall,
      lifetime = 32,
      source = { renderer = 8, modelMembers = { 126, 127 }, animationMembers = { 140, 141, 142, 143 } },
      animation = animation({ 140, 141, 142, 143 }, 8),
    },
    very_tall_grass = {
      model = veryTall,
      lifetime = 32,
      source = { renderer = 12, modelMembers = { 122 }, animationMembers = { 146 } },
      animation = animation({ 146 }, 32),
    },
  }
  local index = {
    schema = "g4-field-effect-index-v1",
    effects = {
      warp_entrance = {
        kind = "model",
        definition = "warp_entrance",
        path = FieldEffectAssetCache.definitionPath("warp_entrance"),
      },
      tall_grass = {
        kind = "animated_model",
        definition = "tall_grass",
        path = FieldEffectAssetCache.definitionPath("tall_grass"),
      },
      very_tall_grass = {
        kind = "animated_model",
        definition = "very_tall_grass",
        path = FieldEffectAssetCache.definitionPath("very_tall_grass"),
      },
    },
  }
  local depHash = hashLua({ memberSha1 = { warpSha, tallSha, veryTallSha }, index = index, effects = effects })
  return {
    model = model,
    index = index,
    effects = effects,
    meshes = meshes,
    textures = textures,
    marker = FieldEffectAssetCache.marker(romFs:metadata().sha1, depHash),
  }
end

return Compiler
