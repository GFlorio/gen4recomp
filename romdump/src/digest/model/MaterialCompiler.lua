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
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")

local MaterialCompiler = {}

-- Bumped whenever the decode changes in a cache-breaking way; part of the
-- content-addressed texture key so the model cache invalidates.
local DECODER_VERSION = "texdec-v1"

-- Decode a texture from ready decoder opts into the shared content-addressed
-- `textures` accumulator and return its sha1 key. The definition string and
-- hash formula are the single authority for texture identity: the base
-- material resolve and the terrain texture-swap decode both call here, so
-- equal texel/palette bytes (base palette included) produce the same key.
-- `texture` is the decoded NSBTX texture record the opts describe.
function MaterialCompiler.decodeTexture(texture, decoderOpts, textures, name)
  local definition = string.format(
    "%d:%dx%d:%s",
    texture.formatRaw,
    texture.width,
    texture.height,
    texture.color0Transparent and "1" or "0"
  )
  local key = Hashing.sha1hex(
    DECODER_VERSION .. definition .. decoderOpts.texel .. decoderOpts.palette .. (decoderOpts.indexData or "")
  )

  if not textures[key] then
    local img = TextureDecoder.decode(decoderOpts, { name = name })
    textures[key] = {
      pixels = img.pixels,
      width = img.width,
      height = img.height,
      alphaUsage = img.alphaUsage,
    }
  end
  return key
end

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

-- Resolve one (textureName, paletteName) bind against `pack` and decode the
-- texture into the shared content-addressed `textures` table. Returns the
-- record fields { texture = key, textureFormat, texWidth, texHeight } with
-- texture nil when the bind fails (the pack does not define the name, or a
-- paletted texture's palette is missing); such failures also append to
-- `unresolved` when that table is supplied. Shared by the model material
-- compile and the NSBTP variant resolution (which binds against the model's
-- embedded TEX0).
function MaterialCompiler.resolveTexture(mat, pack, textures, unresolved, opts)
  opts = opts or {}
  local record = { texture = nil }
  local tex = mat.textureName and pack.textureByName[mat.textureName] or nil
  local pal
  if mat.textureName and not tex then
    if unresolved then
      unresolved[#unresolved + 1] =
        { material = mat.name, kind = "texture", name = mat.textureName, source = describeSource(opts.context) }
    end
  elseif tex and needsPalette(tex.formatRaw) then
    pal = mat.paletteName and pack.paletteByName[mat.paletteName] or nil
    if not pal then
      if unresolved then
        unresolved[#unresolved + 1] = {
          material = mat.name,
          kind = "palette",
          name = mat.paletteName,
          source = describeSource(opts.context),
        }
      end
      tex = nil
    end
  end

  if tex then
    local decoderOpts = Nsbtx.decoderOpts(pack, tex, pal)
    local key = MaterialCompiler.decodeTexture(tex, decoderOpts, textures, mat.textureName)

    record.texture = key
    record.textureFormat = tex.formatRaw
    -- DS texcoords are in texel units; the geometry step divides by these to
    -- normalize UVs to [0,1]. Not serialized into the scene material.
    record.texWidth = tex.width
    record.texHeight = tex.height
  end
  return record
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

    local resolved = MaterialCompiler.resolveTexture(mat, pack, textures, unresolved, {
      context = opts.context,
    })
    record.texture = resolved.texture
    record.textureFormat = resolved.textureFormat
    record.texWidth = resolved.texWidth
    record.texHeight = resolved.texHeight

    if resolved.texture then
      -- The block was located right iff the material's stored original size
      -- matches the texture it binds; a mismatch means a parse offset is wrong.
      if mat.origWidth then
        local tex = pack.textureByName[mat.textureName]
        assert(
          mat.origWidth == tex.width and mat.origHeight == tex.height,
          "material " .. mat.name .. " origWH does not match bound texture " .. mat.textureName
        )
      end
    end

    records[#records + 1] = record
  end

  return { materials = records, textures = textures, unresolved = unresolved }
end

MaterialCompiler.DECODER_VERSION = DECODER_VERSION

return MaterialCompiler
