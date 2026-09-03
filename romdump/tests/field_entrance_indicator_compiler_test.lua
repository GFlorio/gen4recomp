local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")

local T = { tests = {} }

T.tests["compiles source-derived renderer 8 and 12 resources"] = function()
  local names = {
    "romdump.src.digest.FieldEntranceIndicatorCompiler",
    "libs.nds.src.nitro.g3d.Nsbmd",
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
  local invalidSelector = false
  package.loaded["romdump.src.config.FieldEffects"] = {
    archive = { alias = "field_static_models" },
    animationArchive = { alias = "field_static_models" },
    effects = {
      warp_entrance = { renderer = 3, modelMembers = { 85 }, animationMembers = {} },
      tall_grass = {
        renderer = 8,
        modelMembers = { 126 },
        animationMembers = { 140 },
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 12 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      very_tall_grass = {
        renderer = 12,
        modelMembers = { 122 },
        animationMembers = { 146 },
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 12 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      trainer_reveal = {
        renderer = 1,
        modelMembers = { 124 },
        animationMembers = { 148 },
        lifecycle = { mode = "once", frameCount = 7 },
      },
    },
  }
  package.loaded["libs.nds.src.nitro.g3d.Nsbmd"] = {
    decode = function(_, context)
      modelMembers[#modelMembers + 1] = context.memberId
      return {
        models = { { name = "model-" .. context.memberId, materials = { { name = "effect" } } } },
        embeddedTextures = {
          textures = { { name = "texture" } },
          palettes = { { name = "palette" } },
        },
      }
    end,
  }
  package.loaded["romdump.src.digest.FieldEffectPatternAnimation"] = {
    FORMAT = "FIELD_EFFECT_PATTERN",
    decode = function(_, context)
      animationMembers[#animationMembers + 1] = context.memberId
      local lastFrame
      if context.memberId == 146 then
        lastFrame = 119
      elseif context.memberId == 148 then
        lastFrame = 6
      else
        lastFrame = 1
      end
      return {
        lastFrame = lastFrame,
        keys = { { frame = 0, texIdx = invalidSelector and 1 or 0, plttIdx = 0 } },
      }
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

  local ok, result, compiler, romFs = pcall(function()
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
    local romFs = {
      openNarc = function()
        openCount = openCount + 1
        return openCount == 1 and modelNarc or animationNarc
      end,
      metadata = function()
        return { sha1 = "rom-sha1" }
      end,
    }
    return compiler.compile(romFs), compiler, romFs
  end)

  for _, name in ipairs(names) do
    package.loaded[name] = saved[name]
  end
  package.loaded["romdump.src.digest.FieldEntranceIndicatorCompiler"] = nil

  Assert.isTrue(ok, tostring(result))
  Assert.equal(#modelMembers, 4)
  Assert.equal(modelMembers[1], 85)
  Assert.equal(modelMembers[2], 126)
  Assert.equal(modelMembers[3], 122)
  Assert.equal(modelMembers[4], 124)
  Assert.equal(#animationMembers, 3)
  Assert.equal(animationMembers[1], 140)
  Assert.equal(animationMembers[2], 146)
  Assert.equal(animationMembers[3], 148)
  local animation = result.effects.tall_grass.model.animations[1]
  Assert.equal(animation.source.memberId, 140)
  Assert.equal(animation.frameCount, 13)
  Assert.equal(animation.source.type, "field-effect")
  Assert.equal(animation.source.format, "FIELD_EFFECT_PATTERN")
  Assert.equal(result.effects.tall_grass.model.kind, "nitro-dynamic")
  Assert.equal(result.effects.tall_grass.lifecycle.mode, "hold_until_owner_moves")
  Assert.equal(result.effects.tall_grass.lifecycle.holdFrame, 12)
  Assert.isNil(result.effects.tall_grass.source)
  Assert.isNil(result.effects.tall_grass.animationSourceSha1)
  Assert.isNil(result.effects.tall_grass.lifetime)
  Assert.equal(result.effects.very_tall_grass.model.animations[1].frameCount, 120)
  Assert.equal(result.effects.very_tall_grass.model.kind, "nitro-dynamic")
  Assert.isNil(result.effects.very_tall_grass.lifetime)
  Assert.equal(result.effects.trainer_reveal.model.kind, "nitro-dynamic")
  Assert.equal(result.effects.trainer_reveal.lifecycle.mode, "once")
  Assert.equal(result.effects.trainer_reveal.lifecycle.frameCount, 7)
  Assert.isNil(result.effects.trainer_reveal.placementOffset)

  invalidSelector = true
  local invalidOk, invalidErr = pcall(compiler.compile, romFs)
  Assert.isFalse(invalidOk)
  Assert.isTrue(Errors.is(invalidErr))
  Assert.equal(invalidErr.code, "FIELD_EFFECT_SOURCE_INVALID")
end

T.tests["rewrites compiled geometry and texture references into the effect root"] = function()
  local names = {
    "romdump.src.digest.FieldEntranceIndicatorCompiler",
    "libs.nds.src.nitro.g3d.Nsbmd",
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
  package.loaded["libs.nds.src.nitro.g3d.Nsbmd"] = {
    decode = function()
      return {
        models = { { materials = { { name = "effect" } } } },
        embeddedTextures = {
          textures = { { name = "texture" } },
          palettes = { { name = "palette" } },
        },
      }
    end,
  }
  package.loaded["romdump.src.digest.FieldEffectPatternAnimation"] = {
    FORMAT = "FIELD_EFFECT_PATTERN",
    decode = function(_, context)
      local memberId = context and context.memberId or 0
      local lastFrame = memberId == 148 and 6 or 0
      return {
        frameCount = 1,
        keys = { { frame = 0, texIdx = 0, plttIdx = 0 } },
        lastFrame = lastFrame,
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
            return 169
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
