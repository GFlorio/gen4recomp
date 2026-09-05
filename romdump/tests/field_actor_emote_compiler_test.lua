local Assert = require("tests.support.Assert")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")

local T = { tests = {} }

T.tests["rewrites compiled geometry and texture references into the emote root"] = function()
  local names = {
    "romdump.src.digest.actor.FieldActorEmoteCompiler",
    "libs.nds.src.nitro.g3d.Nsbmd",
    "romdump.src.digest.model.ModelAssetCompiler",
    "libs.assets.src.model.ModelAsset",
    "libs.assets.src.field.FieldEmoteAssetCache",
    "romdump.src.digest.Hashing",
  }
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = package.loaded[name]
  end
  local seenMemberId
  package.loaded["libs.nds.src.nitro.g3d.Nsbmd"] = {
    decode = function(_, opts)
      seenMemberId = opts.memberId
      return { models = { {} }, embeddedTextures = {} }
    end,
  }
  package.loaded["romdump.src.digest.model.ModelAssetCompiler"] = {
    compileModel = function(_, _, meshes, textures)
      meshes.mesh = {}
      textures.texture = { width = 1, height = 1, pixels = "pixel" }
      return {
        unresolved = {},
        batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } },
        materials = { { name = "exclamation", texture = "assets/generated/maps/textures/texture.png" } },
      }
    end,
  }
  package.loaded["libs.assets.src.model.ModelAsset"] = { SCHEMA = "g4-model-v1", validate = function() end }
  package.loaded["libs.assets.src.field.FieldEmoteAssetCache"] = {
    SCHEMA = "g4-field-emote-v1",
    geometryPath = FieldEmoteAssetCache.geometryPath,
    texturePath = FieldEmoteAssetCache.texturePath,
    marker = FieldEmoteAssetCache.marker,
    validateDescriptor = function()
      return true
    end,
  }
  package.loaded["romdump.src.digest.Hashing"] = {
    sha1hex = function()
      return "rom-hash"
    end,
    hashLua = function()
      return "dependency-hash"
    end,
  }
  package.loaded["romdump.src.digest.actor.FieldActorEmoteCompiler"] = nil

  local ok, result = pcall(function()
    local compiler = require("romdump.src.digest.actor.FieldActorEmoteCompiler")
    local romFs = {
      openNarc = function()
        return {
          memberCount = function()
            return 169
          end,
          readMember = function()
            return "member-118"
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
  package.loaded["romdump.src.digest.actor.FieldActorEmoteCompiler"] = nil
  Assert.isTrue(ok, tostring(result))
  Assert.equal(seenMemberId, 118, "the exclamation billboard is sourced from field_static_models member 118")
  Assert.equal(result.model.schema, "g4-field-emote-v1")
  Assert.deepEqual(result.model.anchorOffset, { x = 0, y = 2, z = 0.0625 })
  Assert.equal(result.model.model.batches[1].geometry, FieldEmoteAssetCache.geometryPath("mesh"))
  Assert.equal(result.model.model.materials[1].texture, FieldEmoteAssetCache.texturePath("texture"))
  Assert.equal(result.model.model.key, "field-emote:exclamation")
end

T.tests["raises when the archive has no member 118"] = function()
  local ok, err = pcall(function()
    local compiler = require("romdump.src.digest.actor.FieldActorEmoteCompiler")
    local romFs = {
      openNarc = function()
        return {
          memberCount = function()
            return 10
          end,
          readMember = function()
            error("must not read an out-of-range member")
          end,
        }
      end,
      metadata = function()
        return { sha1 = "rom-sha1" }
      end,
    }
    return compiler.compile(romFs)
  end)
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("FIELD_EFFECT_SOURCE_MISSING") ~= nil, tostring(err))
end

return T
