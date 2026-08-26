local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")

local T = { tests = {} }

T.tests["compiles source-derived renderer 8 and 12 resources"] = function()
  local names = {
    "romdump.src.digest.FieldEntranceIndicatorCompiler",
    "romdump.src.digest.nitro.Nsbmd",
    "romdump.src.digest.FieldEffectPatternAnimation",
    "romdump.src.digest.ModelAssetCompiler",
    "romdump.src.digest.MapAssetCompiler",
    "romdump.src.digest.MapPropAnimCompiler",
    "libs.assets.src.ModelAsset",
    "romdump.src.digest.Hashing",
    "romdump.src.config.FieldEffects",
  }
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = package.loaded[name]
  end

  local modelMembers = {}
  local animationMembers = {}
  package.loaded["romdump.src.config.FieldEffects"] = {
    archive = { alias = "field_static_models" },
    animationArchive = { alias = "field_static_models" },
    effects = {
      warp_entrance = { renderer = 3, modelMembers = { 85 }, animationMembers = {} },
      tall_grass = {
        renderer = 8,
        modelMembers = { 126 },
        animationMembers = { 140 },
      },
      very_tall_grass = { renderer = 12, modelMembers = { 122 }, animationMembers = { 146 } },
    },
  }
  package.loaded["romdump.src.digest.nitro.Nsbmd"] = {
    decode = function(_, context)
      modelMembers[#modelMembers + 1] = context.memberId
      return {
        models = { { name = "model-" .. context.memberId, materials = { { name = "effect" } } } },
        embeddedTextures = { textures = {}, palettes = {} },
      }
    end,
  }
  package.loaded["romdump.src.digest.FieldEffectPatternAnimation"] = {
    FORMAT = "FIELD_EFFECT_PATTERN",
    decode = function(_, context)
      animationMembers[#animationMembers + 1] = context.memberId
      local frameCount = context.memberId == 146 and 120 or 2
      return { frameCount = frameCount, keys = { { frame = 0, texIdx = 0, plttIdx = 0xFF } } }
    end,
  }
  package.loaded["romdump.src.digest.ModelAssetCompiler"] = {
    compileModel = function(_, _, _, _, context)
      return {
        unresolved = {},
        batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } },
        materials = { { name = context.modelName, texture = "assets/generated/maps/textures/texture.png" } },
      }
    end,
  }
  package.loaded["romdump.src.digest.MapPropAnimCompiler"] = {
    compileDecoded = function(decoded, opts)
      return {
        id = opts.id,
        name = opts.name,
        category = "material",
        kind = "pattern",
        frameCount = decoded.animations[1].resource.numFrame,
        tracks = { { target = "effect", targetIndex = 0 } },
        semanticNames = {},
        source = opts.source,
        compiled = { targets = { { name = "effect", index = 0 } } },
      }
    end,
  }
  package.loaded["romdump.src.digest.MapAssetCompiler"] = {
    compileDynamicModel = function(_, _, _, animResult, _, memberId, meshes, textures)
      meshes["mesh"] = {}
      textures["texture"] = { width = 1, height = 1, pixels = "pixel" }
      return {
        schema = "g4-model-v1",
        memberId = memberId,
        kind = "nitro-dynamic",
        dynamic = {
          nodes = {},
          transformProgram = {},
          batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } },
        },
        materials = {
          {
            id = 0,
            name = "effect",
            texture = "assets/generated/maps/textures/texture.png",
            wrap = { x = "clamp", y = "clamp" },
            flip = { x = false, y = false },
          },
        },
        animations = animResult.clips,
      }, {}
    end,
  }
  package.loaded["libs.assets.src.ModelAsset"] = {
    SCHEMA = "g4-model-v1",
    validate = function() end,
  }
  package.loaded["romdump.src.digest.Hashing"] = {
    sha1hex = function(bytes)
      return "hash-" .. bytes
    end,
    hashLua = function()
      return "dependency-hash"
    end,
  }
  package.loaded["romdump.src.digest.FieldEntranceIndicatorCompiler"] = nil

  local ok, result = pcall(function()
    local compiler = require("romdump.src.digest.FieldEntranceIndicatorCompiler")
    local modelNarc = {
      memberCount = function()
        return 169
      end,
      readMember = function(_, memberId)
        return "model-" .. memberId
      end,
    }
    local animationNarc = {
      memberCount = function()
        return 169
      end,
      readMember = function(_, memberId)
        return "animation-" .. memberId
      end,
    }
    local openCount = 0
    return compiler.compile({
      openNarc = function()
        openCount = openCount + 1
        return openCount == 1 and modelNarc or animationNarc
      end,
      metadata = function()
        return { sha1 = "rom-sha1" }
      end,
    })
  end)

  for _, name in ipairs(names) do
    package.loaded[name] = saved[name]
  end
  package.loaded["romdump.src.digest.FieldEntranceIndicatorCompiler"] = nil

  Assert.isTrue(ok, tostring(result))
  Assert.equal(#modelMembers, 3)
  Assert.equal(modelMembers[1], 85)
  Assert.equal(modelMembers[2], 126)
  Assert.equal(modelMembers[3], 122)
  Assert.equal(#animationMembers, 2)
  Assert.equal(animationMembers[1], 140)
  Assert.equal(animationMembers[2], 146)
  local animation = result.effects.tall_grass.model.animations[1]
  Assert.equal(animation.source.memberId, 140)
  Assert.equal(animation.frameCount, 2)
  Assert.equal(animation.source.type, "field-effect")
  Assert.equal(animation.source.format, "FIELD_EFFECT_PATTERN")
  Assert.equal(result.effects.tall_grass.model.kind, "nitro-dynamic")
  Assert.equal(result.effects.tall_grass.source.modelMembers[1], 126)
  Assert.equal(result.effects.tall_grass.source.animationMembers[1], 140)
  Assert.isNil(result.effects.tall_grass.lifetime)
  Assert.equal(result.effects.very_tall_grass.model.animations[1].frameCount, 120)
  Assert.equal(result.effects.very_tall_grass.model.kind, "nitro-dynamic")
  Assert.isNil(result.effects.very_tall_grass.lifetime)
end

T.tests["rewrites compiled geometry and texture references into the effect root"] = function()
  local names = {
    "romdump.src.digest.FieldEntranceIndicatorCompiler",
    "romdump.src.digest.nitro.Nsbmd",
    "romdump.src.digest.FieldEffectPatternAnimation",
    "romdump.src.digest.ModelAssetCompiler",
    "romdump.src.digest.MapAssetCompiler",
    "romdump.src.digest.MapPropAnimCompiler",
    "libs.assets.src.ModelAsset",
    "romdump.src.digest.Hashing",
  }
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = package.loaded[name]
  end
  package.loaded["romdump.src.digest.nitro.Nsbmd"] = {
    decode = function()
      return {
        models = { { materials = { { name = "effect" } } } },
        embeddedTextures = { textures = {}, palettes = {} },
      }
    end,
  }
  package.loaded["romdump.src.digest.FieldEffectPatternAnimation"] = {
    FORMAT = "FIELD_EFFECT_PATTERN",
    decode = function()
      return {
        frameCount = 1,
        keys = { { frame = 0, texIdx = 0, plttIdx = 0xFF } },
      }
    end,
  }
  package.loaded["romdump.src.digest.ModelAssetCompiler"] = {
    compileModel = function(_, _, meshes, textures)
      meshes.mesh = {}
      textures.texture = { width = 1, height = 1, pixels = "pixel" }
      return {
        unresolved = {},
        batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } },
        materials = { { name = "effect", texture = "assets/generated/maps/textures/texture.png" } },
      }
    end,
  }
  package.loaded["romdump.src.digest.MapPropAnimCompiler"] = {
    compileDecoded = function(decoded, opts)
      return {
        id = opts.id,
        name = opts.name,
        category = "joint",
        kind = "trs",
        frameCount = decoded.animations[1].resource.numFrame,
        tracks = { { target = "target", targetIndex = 0 } },
        semanticNames = {},
        source = opts.source,
        compiled = {},
      }
    end,
  }
  package.loaded["romdump.src.digest.MapAssetCompiler"] = {
    compileDynamicModel = function(_, _, _, animResult, _, memberId, meshes, textures)
      meshes.mesh = {}
      textures.texture = { width = 1, height = 1, pixels = "pixel" }
      return {
        schema = "g4-model-v1",
        memberId = memberId,
        kind = "nitro-dynamic",
        dynamic = {
          nodes = {},
          transformProgram = {},
          batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } },
        },
        materials = { { id = 0, name = "effect", texture = "assets/generated/maps/textures/texture.png" } },
        animations = animResult.clips,
      }, {}
    end,
  }
  package.loaded["libs.assets.src.ModelAsset"] = { SCHEMA = "g4-model-v1", validate = function() end }
  package.loaded["romdump.src.digest.Hashing"] = {
    sha1hex = function()
      return "rom-hash"
    end,
    hashLua = function()
      return "dependency-hash"
    end,
  }
  package.loaded["romdump.src.digest.FieldEntranceIndicatorCompiler"] = nil

  local ok, result = pcall(function()
    local compiler = require("romdump.src.digest.FieldEntranceIndicatorCompiler")
    local romFs = {
      openNarc = function()
        return {
          memberCount = function()
            return 147
          end,
          readMember = function()
            return "member-85"
          end,
        }
      end,
      metadata = function()
        return { sha1 = "rom-sha1" }
      end,
    }
    return compiler.compile(romFs)
  end)
  for _, name in ipairs(names) do
    package.loaded[name] = saved[name]
  end
  package.loaded["romdump.src.digest.FieldEntranceIndicatorCompiler"] = nil
  Assert.isTrue(ok, tostring(result))
  Assert.equal(result.model.batches[1].geometry, FieldEffectAssetCache.geometryPath("mesh"))
  Assert.equal(result.model.materials[1].texture, FieldEffectAssetCache.texturePath("texture"))
  Assert.isNil(result.model.memberId)
  Assert.isNil(result.manifest)
  Assert.isNil(result.archive)
  Assert.isNil(result.memberId)
  Assert.isNil(result.romSha1)
end

return T
