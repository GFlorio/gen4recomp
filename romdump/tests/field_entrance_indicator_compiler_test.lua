local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")

local T = { tests = {} }

T.tests["compiles source-derived renderer 8 and 12 resources"] = function()
  local names = {
    "romdump.src.digest.FieldEntranceIndicatorCompiler",
    "romdump.src.digest.nitro.Nsbmd",
    "romdump.src.digest.nitro.NitroAnimation",
    "romdump.src.digest.ModelAssetCompiler",
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
    animationArchive = { alias = "build_anim" },
    effects = {
      warp_entrance = { renderer = 3, modelMembers = { 85 }, animationMembers = {} },
      tall_grass = {
        renderer = 8,
        modelMembers = { 126, 127 },
        animationMembers = { 140, 141, 142, 143 },
      },
      very_tall_grass = { renderer = 12, modelMembers = { 122 }, animationMembers = { 146 } },
    },
  }
  package.loaded["romdump.src.digest.nitro.Nsbmd"] = {
    decode = function(_, context)
      modelMembers[#modelMembers + 1] = context.memberId
      return { models = { { name = "model-" .. context.memberId } }, embeddedTextures = {} }
    end,
  }
  local animationFormats = { [140] = "NSBTA", [141] = "NSBTA", [142] = "NSBTP", [143] = "NSBTA", [146] = "NSBTA" }
  package.loaded["romdump.src.digest.nitro.NitroAnimation"] = {
    decode = function(_, context)
      animationMembers[#animationMembers + 1] = context.memberId
      local frameCount = context.memberId == 146 and 120 or context.memberId == 142 and 60 or 2
      return {
        format = animationFormats[context.memberId],
        animations = {
          {
            name = "source-" .. context.memberId,
            resource = { numFrame = frameCount, targets = { { name = "target" } } },
          },
        },
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
        return 273
      end,
      readMember = function(_, memberId)
        return "animation-" .. memberId
      end,
    }
    return compiler.compile({
      openNarc = function(_, alias)
        return alias == "build_anim" and animationNarc or modelNarc
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
  Assert.equal(#modelMembers, 4)
  Assert.equal(modelMembers[1], 85)
  Assert.equal(modelMembers[2], 126)
  Assert.equal(modelMembers[3], 127)
  Assert.equal(modelMembers[4], 122)
  Assert.equal(#animationMembers, 5)
  Assert.equal(animationMembers[1], 140)
  Assert.equal(animationMembers[2], 141)
  Assert.equal(animationMembers[3], 142)
  Assert.equal(animationMembers[4], 143)
  Assert.equal(animationMembers[5], 146)
  local animation = result.effects.tall_grass.animation
  Assert.equal(animation.frames[1].memberId, 140)
  Assert.equal(animation.frames[1].duration, 2)
  Assert.equal(animation.frames[1].format, "NSBTA")
  Assert.equal(result.effects.tall_grass.lifetime, 66)
  Assert.equal(result.effects.very_tall_grass.animation.frames[1].duration, 120)
  Assert.equal(result.effects.very_tall_grass.lifetime, 120)
end

T.tests["rewrites compiled geometry and texture references into the effect root"] = function()
  local names = {
    "romdump.src.digest.FieldEntranceIndicatorCompiler",
    "romdump.src.digest.nitro.Nsbmd",
    "romdump.src.digest.nitro.NitroAnimation",
    "romdump.src.digest.ModelAssetCompiler",
    "libs.assets.src.ModelAsset",
    "romdump.src.digest.Hashing",
  }
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = package.loaded[name]
  end
  package.loaded["romdump.src.digest.nitro.Nsbmd"] = {
    decode = function()
      return { models = { {} }, embeddedTextures = {} }
    end,
  }
  package.loaded["romdump.src.digest.nitro.NitroAnimation"] = {
    decode = function()
      return {
        format = "NSBTA",
        animations = { { name = "fixture", resource = { numFrame = 1 } } },
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
