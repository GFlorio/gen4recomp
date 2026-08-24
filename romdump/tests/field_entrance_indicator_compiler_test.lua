local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")

local T = { tests = {} }

T.tests["rewrites compiled geometry and texture references into the effect root"] = function()
  local names = {
    "romdump.src.digest.FieldEntranceIndicatorCompiler",
    "romdump.src.digest.nitro.Nsbmd",
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
            return 86
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
