-- MaterialCompiler: textured materials get a content hash + decoded asset,
-- untextured materials get none, identical texture references deduplicate, and a
-- name the bound pack does not define yields an untextured material plus a
-- reported unresolved binding -- what the DS draws, since no HGSS material stores
-- a texture format or address of its own for a failed bind to fall back on.

local Assert = require("tests.support.Assert")
local MaterialCompiler = require("romdump.src.digest.MaterialCompiler")
local TexFixture = require("tests.support.Tex0Fixture")

local T = {}

-- One 8x8 palette16 texture "t" (all texels index 1) + palette "p".
local function buildPack()
  return TexFixture.pack({ textures = { "t" }, palettes = { "p" } })
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function T.textured_untextured_and_dedup()
  local out = MaterialCompiler.compile({
    { index = 0, name = "m0", textureName = "t", paletteName = "p" },
    { index = 1, name = "m1" }, -- untextured
    { index = 2, name = "m2", textureName = "t", paletteName = "p" }, -- same texture -> dedup
  }, buildPack())

  Assert.equal(#out.materials, 3)
  Assert.equal(#out.materials[1].texture, 40) -- 40 hex chars
  Assert.isNil(out.materials[2].texture)
  Assert.equal(out.materials[1].texture, out.materials[3].texture)
  Assert.equal(countKeys(out.textures), 1) -- deduplicated

  local asset = out.textures[out.materials[1].texture]
  Assert.equal(asset.width, 8)
  Assert.equal(#asset.pixels, 8 * 8 * 4)
  Assert.isTrue(asset.alphaUsage.hasOpaque)
  Assert.isFalse(asset.alphaUsage.hasZero)
  Assert.isFalse(asset.alphaUsage.hasPartial)
  Assert.equal(out.materials[1].textureFormat, 3)
  Assert.isNil(out.materials[1].alphaMode)
  Assert.isNil(out.materials[1].cullMode)
end

function T.resolved_materials_report_nothing_unresolved()
  local out = MaterialCompiler.compile(
    { { index = 0, name = "m", textureName = "t", paletteName = "p" } }, buildPack())
  Assert.deepEqual(out.unresolved, {})
end

function T.missing_texture_compiles_untextured_and_is_reported()
  local out = MaterialCompiler.compile(
    { { index = 0, name = "m", textureName = "nope", paletteName = "p" } }, buildPack(),
    { context = { textureArchive = "map_textures", textureMemberId = 42 } })

  Assert.isNil(out.materials[1].texture)
  Assert.equal(#out.unresolved, 1)
  Assert.equal(out.unresolved[1].material, "m")
  Assert.equal(out.unresolved[1].kind, "texture")
  Assert.equal(out.unresolved[1].name, "nope")
  Assert.equal(out.unresolved[1].source, "map_textures member 42")
end

function T.missing_palette_compiles_untextured_and_is_reported()
  -- Paletted format with no palette name: the texture exists but cannot be
  -- decoded, so the DS has nothing bound either.
  local out = MaterialCompiler.compile(
    { { index = 0, name = "m", textureName = "t" } }, buildPack())

  Assert.isNil(out.materials[1].texture)
  Assert.equal(#out.unresolved, 1)
  Assert.equal(out.unresolved[1].kind, "palette")
end

function T.an_unresolved_material_keeps_its_wrap_and_flip()
  -- Wrap/flip come from the material's own register, which a failed bind leaves
  -- untouched; only the texture reference is lost.
  local out = MaterialCompiler.compile(
    { { index = 0, name = "m", textureName = "nope", repeatX = true, flipY = true } },
    buildPack())
  Assert.equal(out.materials[1].wrap.x, "repeat")
  Assert.isTrue(out.materials[1].flip.y)
end

return T
