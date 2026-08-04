-- Compiles a model's materials into normalized render records and decodes each
-- referenced texture once into a content-addressed RGBA asset. Texture/palette
-- names are matched exactly against the supplied pack (an area texture pack or a
-- model's embedded TEX0); a missing reference is a hard compiler error naming
-- the material and expected name. Textures sharing identical source bytes
-- deduplicate to one asset keyed by SHA-1 over the decoder version plus the
-- texture definition and raw texel/palette bytes. Pure domain module.

local Errors = require("src.import.Errors")
local Hashing = require("src.import.Hashing")
local Nsbtx = require("src.data.nitro.Nsbtx")
local TextureDecoder = require("src.data.nitro.TextureDecoder")

local MaterialCompiler = {}

-- Bumping this re-addresses every generated texture (its bytes may change).
local DECODER_VERSION = "texdec-v1"

-- Paletted formats require a palette; direct color (7) and none (0) do not.
local function needsPalette(formatRaw)
  return formatRaw >= 1 and formatRaw <= 6
end

local function wrapMode(repeats) return repeats and "repeat" or "clamp" end

-- materials: list of { index, name, textureName?, paletteName? }.
-- pack: an Nsbtx.decode result. Returns { materials = {...}, textures = { [sha1] = {pixels,width,height,alphaUsage} } }.
function MaterialCompiler.compile(materials, pack, opts)
  opts = opts or {}
  local records, textures = {}, {}

  for _, mat in ipairs(materials) do
    local record = {
      id = mat.index,
      name = mat.name,
      texture = nil,
      wrap = { x = "clamp", y = "clamp" },
      flip = { x = false, y = false },
      diffuse = { r = 255, g = 255, b = 255, a = 255 },
    }

    if mat.textureName then
      local tex = pack.textureByName[mat.textureName]
      if not tex then
        Errors.raise("MAP_COMPILE_MISSING_TEXTURE",
          "material texture not found in pack: " .. mat.textureName,
          { material = mat.name, expected = mat.textureName, context = opts.context })
      end
      local pal
      if needsPalette(tex.formatRaw) then
        pal = mat.paletteName and pack.paletteByName[mat.paletteName]
        if not pal then
          Errors.raise("MAP_COMPILE_MISSING_PALETTE",
            "material palette not found in pack: " .. tostring(mat.paletteName),
            { material = mat.name, expected = mat.paletteName, texture = mat.textureName, context = opts.context })
        end
      end

      local decoderOpts = Nsbtx.decoderOpts(pack, tex, pal)
      local definition = string.format("%d:%dx%d:%s", tex.formatRaw, tex.width, tex.height,
        tex.color0Transparent and "1" or "0")
      local key = Hashing.sha1hex(DECODER_VERSION .. definition
        .. decoderOpts.texel .. decoderOpts.palette .. (decoderOpts.indexData or ""))

      if not textures[key] then
        local img = TextureDecoder.decode(decoderOpts, { name = mat.textureName })
        textures[key] = {
          pixels = img.pixels,
          width = img.width,
          height = img.height,
          alphaUsage = img.alphaUsage,
        }
      end

      -- The block was located right iff the material's stored original size
      -- matches the texture it binds; a mismatch means a parse offset is wrong.
      if mat.origWidth then
        assert(mat.origWidth == tex.width and mat.origHeight == tex.height,
          "material " .. mat.name .. " origWH does not match bound texture " .. mat.textureName)
      end

      record.texture = key
      record.textureFormat = tex.formatRaw
      -- DS texcoords are in texel units; the geometry step divides by these to
      -- normalize UVs to [0,1]. Not serialized into the scene material.
      record.texWidth = tex.width
      record.texHeight = tex.height
      -- Wrap/flip come from the material's texImageParam (what the DS programs
      -- per material), not the NSBTX texture template -- the template reads
      -- clamp for map textures, which collapses tiling UVs (e.g. flowers).
      record.wrap = { x = wrapMode(mat.repeatX), y = wrapMode(mat.repeatY) }
      record.flip = { x = mat.flipX or false, y = mat.flipY or false }
    end

    records[#records + 1] = record
  end

  return { materials = records, textures = textures }
end

MaterialCompiler.DECODER_VERSION = DECODER_VERSION

return MaterialCompiler
