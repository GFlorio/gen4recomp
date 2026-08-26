-- Compiles HGSS field effects from the curated model and animation archives.
-- Nitro decoding ends here; the runtime receives only normalized model data
-- and content-addressed mesh/texture references.

local Errors = require("libs.errors.src.Errors")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local FieldEffectPatternAnimation = require("romdump.src.digest.FieldEffectPatternAnimation")
local ModelAssetCompiler = require("romdump.src.digest.ModelAssetCompiler")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.MapPropAnimCompiler")
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

local function rewriteEffectPaths(descriptor)
  for _, batch in ipairs(descriptor.dynamic.batches) do
    local sha1 = assert(batch.geometry:match("/([^/]+)%.g4mesh$"))
    batch.geometry = FieldEffectAssetCache.geometryPath(sha1)
  end
  for _, material in ipairs(descriptor.materials) do
    if material.texture then
      local sha1 = assert(material.texture:match("/([^/]+)%.png$"))
      material.texture = FieldEffectAssetCache.texturePath(sha1)
    end
    for _, variant in ipairs(material.variants or {}) do
      if variant.texture then
        local sha1 = assert(variant.texture:match("/([^/]+)%.png$"))
        variant.texture = FieldEffectAssetCache.texturePath(sha1)
      end
    end
  end
end

local function compileDynamicModel(
  narc,
  animationNarc,
  animationArchive,
  modelMemberId,
  animationMemberId,
  key,
  section,
  role
)
  local modelBytes = member(narc, modelMemberId)
  local decodedModel = assert(Nsbmd.decode(modelBytes, {
    alias = "field_static_models",
    memberId = modelMemberId,
    section = section,
  }))
  local model = decodedModel.models[1]
  if not model or not decodedModel.embeddedTextures then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect dynamic model is incomplete", {
      archive = "field_static_models",
      memberId = modelMemberId,
    })
  end

  local animationBytes = member(animationNarc, animationMemberId, animationArchive)
  local decodedPattern, err = FieldEffectPatternAnimation.decode(animationBytes, {
    alias = animationArchive,
    memberId = animationMemberId,
    section = "field-effect-grass-animation",
  })
  if not decodedPattern then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect animation could not be decoded", {
      archive = animationArchive,
      memberId = animationMemberId,
      error = err,
    })
  end
  assert(decodedPattern)
  local material = model.materials[1]
  if not material then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect model has no material target", {
      archive = "field_static_models",
      memberId = modelMemberId,
    })
  end
  local textureNames, paletteNames = {}, {}
  for _, texture in ipairs(decodedModel.embeddedTextures.textures) do
    textureNames[#textureNames + 1] = texture.name
  end
  for _, palette in ipairs(decodedModel.embeddedTextures.palettes) do
    paletteNames[#paletteNames + 1] = palette.name
  end
  local keys = {}
  for _, keyFrame in ipairs(decodedPattern.keys) do
    local paletteIndex = keyFrame.plttIdx
    if paletteIndex == 0xFF then
      if #paletteNames == 1 then
        paletteIndex = 0
      elseif #paletteNames == #textureNames then
        paletteIndex = keyFrame.texIdx
      elseif #paletteNames > 1 then
        Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect animation has ambiguous palette mapping", {
          archive = animationArchive,
          memberId = animationMemberId,
          textureCount = #textureNames,
          paletteCount = #paletteNames,
        })
      end
    end
    keys[#keys + 1] = { frame = keyFrame.frame, texIdx = keyFrame.texIdx, plttIdx = paletteIndex }
  end
  local normalizedAnimation = {
    format = "NSBTP",
    bytes = animationBytes,
    animations = {
      {
        name = "field-effect-pattern",
        resource = {
          numFrame = decodedPattern.frameCount,
          textureNames = textureNames,
          paletteNames = paletteNames,
          targets = {
            {
              index = 0,
              name = material.name,
              rate = 1,
              keys = keys,
            },
          },
        },
      },
    },
  }
  local clip = MapPropAnimCompiler.compileDecoded(normalizedAnimation, {
    name = normalizedAnimation.animations[1].name,
    id = key .. ":animation",
    source = {
      type = "field-effect",
      format = FieldEffectPatternAnimation.FORMAT,
      archive = animationArchive,
      memberId = animationMemberId,
      sha1 = Hashing.sha1hex(animationBytes),
    },
  })
  local meshes, textures = {}, {}
  local descriptor, unresolved = MapAssetCompiler.compileDynamicModel(
    model,
    decodedModel,
    decodedModel.embeddedTextures,
    { clips = { clip } },
    {
      role = role,
      modelArchive = "field_static_models",
      modelMemberId = modelMemberId,
      modelName = model.name,
      textureArchive = "field_static_models",
      textureMemberId = modelMemberId,
    },
    modelMemberId,
    textures,
    meshes
  )
  if #unresolved > 0 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect dynamic model has unresolved materials", {
      archive = "field_static_models",
      memberId = modelMemberId,
      unresolved = unresolved,
    })
  end
  descriptor.key = key
  rewriteEffectPaths(descriptor)
  ModelAsset.validate(descriptor)
  return descriptor, meshes, textures, Hashing.sha1hex(modelBytes), Hashing.sha1hex(animationBytes)
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
  local tall, tallMeshes, tallTextures, tallSha, tallAnimationSha = compileDynamicModel(
    narc,
    animationNarc,
    FieldEffects.animationArchive.alias,
    FieldEffects.effects.tall_grass.modelMembers[1],
    FieldEffects.effects.tall_grass.animationMembers[1],
    "field-effect:tall-grass",
    "tall-grass-renderer-8",
    "field-effect-grass"
  )
  local veryTall, veryTallMeshes, veryTallTextures, veryTallSha, veryTallAnimationSha = compileDynamicModel(
    narc,
    animationNarc,
    FieldEffects.animationArchive.alias,
    FieldEffects.effects.very_tall_grass.modelMembers[1],
    FieldEffects.effects.very_tall_grass.animationMembers[1],
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
  for sha1, mesh in pairs(veryTallMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(veryTallTextures) do
    textures[sha1] = texture
  end
  local effects = {
    warp_entrance = {
      model = model,
      lifetime = 1,
    },
    tall_grass = {
      model = tall,
      source = FieldEffectAssetCache.source("tall_grass"),
      animationSourceSha1 = tallAnimationSha,
    },
    very_tall_grass = {
      model = veryTall,
      source = FieldEffectAssetCache.source("very_tall_grass"),
      animationSourceSha1 = veryTallAnimationSha,
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
