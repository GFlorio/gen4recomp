-- Compiles a model's materials into normalized render records and decodes each
-- referenced texture once into a content-addressed RGBA asset. Texture/palette
-- names are matched exactly against the supplied pack (an area texture pack or a
-- model's embedded TEX0). A name the pack does not define yields an untextured
-- material, listed in `unresolved` for the caller to report: no HGSS material
-- stores a texture format or address of its own -- every one is zero until a
-- successful bind writes it -- so Nitro's name-based bind failing leaves the DS
-- drawing that material with no texture at all. Textures sharing identical
-- source bytes deduplicate to one asset keyed by SHA-1 over the texture
-- definition and raw texel/palette bytes; implementation changes to the
-- decoder invalidate through the producer fingerprint, which forces a full
-- derived rebuild. Pure domain module.

local Hashing = require("romdump.src.digest.Hashing")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")
local TextureDecoder = require("romdump.src.digest.nitro.TextureDecoder")

local MaterialCompiler = {}

-- Paletted formats require a palette; direct color (7) and none (0) do not.
local function needsPalette(formatRaw)
  return formatRaw >= 1 and formatRaw <= 6
end

local function wrapMode(repeats)
  return repeats and "repeat" or "clamp"
end

-- "building_textures member 7" -- names the resource that was actually searched,
-- so a miss is attributable without re-running the audit.
local function describeSource(context)
  if not (context and context.textureArchive) then
    return "the supplied pack"
  end
  if not context.textureMemberId then
    return context.textureArchive
  end
  return context.textureArchive .. " member " .. context.textureMemberId
end

-- materials: list of { index, name, textureName?, paletteName? }.
-- pack: an Nsbtx.decode result. Returns { materials = {...}, textures = { [sha1] =
-- {pixels,width,height,alphaUsage} }, unresolved = { {material,kind,name,source} } }.
function MaterialCompiler.compile(materials, pack, opts)
  opts = opts or {}
  local records, textures, unresolved = {}, {}, {}

  for _, mat in ipairs(materials) do
    local record = {
      id = mat.index,
      name = mat.name,
      texture = nil,
      wrap = { x = "clamp", y = "clamp" },
      flip = { x = false, y = false },
      diffuse = { r = 255, g = 255, b = 255, a = 255 },
    }

    -- Wrap/flip come from the material's texImageParam (what the DS programs per
    -- material), not the NSBTX texture template -- the template reads clamp for
    -- map textures, which collapses tiling UVs (e.g. flowers). A failed bind
    -- leaves them as the material stored them, so they are read unconditionally.
    if mat.textureName then
      record.wrap = { x = wrapMode(mat.repeatX), y = wrapMode(mat.repeatY) }
      record.flip = { x = mat.flipX or false, y = mat.flipY or false }
    end

    local tex = mat.textureName and pack.textureByName[mat.textureName] or nil
    local pal
    if mat.textureName and not tex then
      unresolved[#unresolved + 1] =
        { material = mat.name, kind = "texture", name = mat.textureName, source = describeSource(opts.context) }
    elseif tex and needsPalette(tex.formatRaw) then
      pal = mat.paletteName and pack.paletteByName[mat.paletteName] or nil
      if not pal then
        unresolved[#unresolved + 1] = {
          material = mat.name,
          kind = "palette",
          name = mat.paletteName,
          source = describeSource(opts.context),
        }
        tex = nil
      end
    end

    if tex then
      local decoderOpts = Nsbtx.decoderOpts(pack, tex, pal)
      local definition =
        string.format("%d:%dx%d:%s", tex.formatRaw, tex.width, tex.height, tex.color0Transparent and "1" or "0")
      local key =
        Hashing.sha1hex(definition .. decoderOpts.texel .. decoderOpts.palette .. (decoderOpts.indexData or ""))

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
        assert(
          mat.origWidth == tex.width and mat.origHeight == tex.height,
          "material " .. mat.name .. " origWH does not match bound texture " .. mat.textureName
        )
      end

      record.texture = key
      record.textureFormat = tex.formatRaw
      -- DS texcoords are in texel units; the geometry step divides by these to
      -- normalize UVs to [0,1]. Not serialized into the scene material.
      record.texWidth = tex.width
      record.texHeight = tex.height
    end

    records[#records + 1] = record
  end

  return { materials = records, textures = textures, unresolved = unresolved }
end

return MaterialCompiler
