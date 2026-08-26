-- Compiles HGSS field effects from the curated model and animation archives.
-- Nitro decoding ends here; the runtime receives only normalized model data
-- and content-addressed mesh/texture references.

local Errors = require("libs.errors.src.Errors")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local NitroAnimation = require("romdump.src.digest.nitro.NitroAnimation")
local ModelAssetCompiler = require("romdump.src.digest.ModelAssetCompiler")
local ModelAsset = require("libs.assets.src.ModelAsset")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local Hashing = require("romdump.src.digest.Hashing")
local FieldEffects = require("romdump.src.config.FieldEffects")
local Contract = require("libs.assets.src.DerivedAssetContract")

local Compiler = {}

local function member(narc, memberId, archive)
  if memberId < 0 or memberId >= narc:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "field-effect source member is unavailable", {
      archive = archive or "field_static_models",
      memberId = memberId,
      count = narc:memberCount(),
    })
  end
  return assert(narc:readMember(memberId))
end

local function sourceHashes(narc, members, archive)
  local hashes = {}
  for _, memberId in ipairs(members) do
    hashes[#hashes + 1] = { memberId = memberId, sha1 = Hashing.sha1hex(member(narc, memberId, archive)) }
  end
  return hashes
end

local function animation(narc, members)
  local frames = {}
  for _, memberId in ipairs(members) do
    local bytes = member(narc, memberId, "build_anim")
    local decoded, err = NitroAnimation.decode(bytes, {
      alias = "build_anim",
      memberId = memberId,
      section = "field-effect-grass-animation",
    })
    if not decoded then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "grass animation could not be decoded", {
        archive = "build_anim",
        memberId = memberId,
        error = err,
      })
    end
    assert(decoded)
    if #decoded.animations ~= 1 then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "grass animation must contain one animation", {
        archive = "build_anim",
        memberId = memberId,
        count = #decoded.animations,
      })
    end
    local sourceAnimation = decoded.animations[1]
    local resource = sourceAnimation.resource
    if type(resource) ~= "table" or type(resource.numFrame) ~= "number" or resource.numFrame < 1 then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "grass animation has no positive source frame count", {
        archive = "build_anim",
        memberId = memberId,
      })
    end
    frames[#frames + 1] = {
      memberId = memberId,
      duration = resource.numFrame,
      format = decoded.format,
      name = sourceAnimation.name,
      values = { resource },
    }
  end
  return {
    schema = "g4-field-effect-animation-v1",
    sourceMembers = members,
    frames = frames,
  }
end

local function animationLifetime(value)
  local lifetime = 0
  for _, frame in ipairs(value.frames) do
    lifetime = lifetime + frame.duration
  end
  return lifetime
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
  local narc = assert(romFs:openNarc(FieldEffects.archive.alias))
  local animationNarc = assert(romFs:openNarc(FieldEffects.animationArchive.alias))
  local sourceHashesByKind = {}
  for kind, source in pairs(FieldEffects.effects) do
    sourceHashesByKind[kind] = {
      model = sourceHashes(narc, source.modelMembers, FieldEffects.archive.alias),
      animation = sourceHashes(animationNarc, source.animationMembers, FieldEffects.animationArchive.alias),
    }
  end
  local model, meshes, textures, warpSha = compileModel(
    narc,
    FieldEffects.effects.warp_entrance.modelMembers[1],
    "field-effect:warp-entrance",
    "warp-entrance-effect",
    "field-effect"
  )
  local tall, tallMeshes, tallTextures, tallSha = compileModel(
    narc,
    FieldEffects.effects.tall_grass.modelMembers[1],
    "field-effect:tall-grass",
    "tall-grass-renderer-8",
    "field-effect-grass"
  )
  local _, tallSecondaryMeshes, tallSecondaryTextures = compileModel(
    narc,
    FieldEffects.effects.tall_grass.modelMembers[2],
    "field-effect:tall-grass-secondary",
    "tall-grass-renderer-8-secondary",
    "field-effect-grass"
  )
  local veryTall, veryTallMeshes, veryTallTextures, veryTallSha = compileModel(
    narc,
    FieldEffects.effects.very_tall_grass.modelMembers[1],
    "field-effect:very-tall-grass",
    "tall-grass-renderer-12",
    "field-effect-grass"
  )
  for sha1, mesh in pairs(tallMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(tallTextures) do
    textures[sha1] = texture
  end
  for sha1, mesh in pairs(tallSecondaryMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(tallSecondaryTextures) do
    textures[sha1] = texture
  end
  for sha1, mesh in pairs(veryTallMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(veryTallTextures) do
    textures[sha1] = texture
  end
  local tallAnimation = animation(animationNarc, FieldEffects.effects.tall_grass.animationMembers)
  local veryTallAnimation = animation(animationNarc, FieldEffects.effects.very_tall_grass.animationMembers)
  local effects = {
    warp_entrance = {
      model = model,
      lifetime = 1,
    },
    tall_grass = {
      model = tall,
      lifetime = animationLifetime(tallAnimation),
      source = FieldEffectAssetCache.source("tall_grass"),
      animation = tallAnimation,
    },
    very_tall_grass = {
      model = veryTall,
      lifetime = animationLifetime(veryTallAnimation),
      source = FieldEffectAssetCache.source("very_tall_grass"),
      animation = veryTallAnimation,
    },
  }
  local index = {
    schema = Contract.fieldEffects.indexSchema,
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
  local depHash = hashLua({
    memberSha1 = { warpSha, tallSha, veryTallSha },
    sourceHashes = sourceHashesByKind,
    index = index,
    effects = effects,
  })
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
