-- Decodes a Nitro texture to RGBA8 pixels. Takes a decoupled descriptor
-- (format, dimensions, and the raw texel/palette/index byte slices) so it can
-- be unit tested with exact fixtures and reused for both standalone BTX0 and
-- embedded TEX0 textures. Decode rules follow GBATEK "DS Video Texture Data"
-- and spec section 16. Output is row-major, top-left origin, straight (not
-- premultiplied) alpha. Also reports alphaUsage (hasZero, hasPartial,
-- hasOpaque) derived from the decoded alpha bytes so the compiler can classify
-- the material without re-scanning the texture. Pure domain module, arithmetic
-- bit extraction only.

local Errors = require("libs.rom.src.Errors")
local FixedPoint = require("libs.math.src.FixedPoint")

local TextureDecoder = {}

local function byteAt(s, i) return string.byte(s, i + 1) or 0 end

local function paletteColor(palette, index)
  local off = index * 2
  return FixedPoint.rgb555(byteAt(palette, off) + byteAt(palette, off + 1) * 256)
end

-- Build an RGBA8 string from a per-texel sampler(x, y) -> r, g, b, a.
local function assemble(width, height, sampler)
  local px = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local r, g, b, a = sampler(x, y)
      px[#px + 1] = string.char(r, g, b, a)
    end
  end
  return table.concat(px)
end

-- Paletted sampler shared by formats 2/3/4: index(x, y) -> palette index.
local function palettedSampler(palette, color0Transparent, index)
  return function(x, y)
    local i = index(x, y)
    local r, g, b = paletteColor(palette, i)
    local a = 255
    if color0Transparent and i == 0 then a = 0 end
    return r, g, b, a
  end
end

local DECODERS = {}

-- Format 1: A3I5 -- 5-bit palette index, 3-bit alpha, one byte per texel.
DECODERS[1] = function(o)
  return assemble(o.width, o.height, function(x, y)
    local v = byteAt(o.texel, y * o.width + x)
    local index = v % 32
    local alpha3 = math.floor(v / 32)
    local r, g, b = paletteColor(o.palette, index)
    return r, g, b, math.floor(alpha3 * 255 / 7 + 0.5)
  end)
end

-- Format 2: 4-color -- 2-bit indices, 4 texels per byte, LSB first.
DECODERS[2] = function(o)
  return assemble(o.width, o.height, palettedSampler(o.palette, o.color0Transparent, function(x, y)
    local linear = y * o.width + x
    local v = byteAt(o.texel, math.floor(linear / 4))
    return math.floor(v / 4 ^ (linear % 4)) % 4
  end))
end

-- Format 3: 16-color -- 4-bit indices, 2 texels per byte, low nibble first.
DECODERS[3] = function(o)
  return assemble(o.width, o.height, palettedSampler(o.palette, o.color0Transparent, function(x, y)
    local linear = y * o.width + x
    local v = byteAt(o.texel, math.floor(linear / 2))
    if linear % 2 == 0 then return v % 16 end
    return math.floor(v / 16) % 16
  end))
end

-- Format 4: 256-color -- one 8-bit index per texel.
DECODERS[4] = function(o)
  return assemble(o.width, o.height, palettedSampler(o.palette, o.color0Transparent, function(x, y)
    return byteAt(o.texel, y * o.width + x)
  end))
end

-- Format 6: A5I3 -- 3-bit palette index, 5-bit alpha, one byte per texel.
DECODERS[6] = function(o)
  return assemble(o.width, o.height, function(x, y)
    local v = byteAt(o.texel, y * o.width + x)
    local index = v % 8
    local alpha5 = math.floor(v / 8)
    local r, g, b = paletteColor(o.palette, index)
    return r, g, b, math.floor(alpha5 * 255 / 31 + 0.5)
  end)
end

-- Format 7: direct color -- 16-bit BGR555 per texel, bit15 is the alpha bit.
DECODERS[7] = function(o)
  return assemble(o.width, o.height, function(x, y)
    local off = (y * o.width + x) * 2
    local v = byteAt(o.texel, off) + byteAt(o.texel, off + 1) * 256
    local r, g, b = FixedPoint.rgb555(v)
    local a = (v >= 0x8000) and 255 or 0
    return r, g, b, a
  end)
end

-- Weighted blend of two palette colors, rounded. num/den is color A's weight.
local function blend(palette, a, b, numA, den)
  local ra, ga, ba = paletteColor(palette, a)
  local rb, gb, bb = paletteColor(palette, b)
  local numB = den - numA
  local function mix(ca, cb) return math.floor((ca * numA + cb * numB) / den + 0.5) end
  return mix(ra, rb), mix(ga, gb), mix(ba, bb)
end

-- Format 5: 4x4 compressed. Texels are 2-bit, one byte per block row; each
-- block has a u16 control word in the index data selecting a palette base and
-- interpolation mode.
DECODERS[5] = function(o)
  local blocksPerRow = math.floor(o.width / 4)
  return assemble(o.width, o.height, function(x, y)
    local bx, by = math.floor(x / 4), math.floor(y / 4)
    local blockIndex = by * blocksPerRow + bx
    local rowByte = byteAt(o.texel, blockIndex * 4 + (y % 4))
    local texel = math.floor(rowByte / 4 ^ (x % 4)) % 4

    local control = byteAt(o.indexData, blockIndex * 2)
      + byteAt(o.indexData, blockIndex * 2 + 1) * 256
    local base = (control % 0x4000) * 2
    local mode = math.floor(control / 0x4000)

    if texel == 0 or texel == 1 then
      local r, g, b = paletteColor(o.palette, base + texel)
      return r, g, b, 255
    end
    if mode == 0 then -- 0,1,2 from palette; 3 transparent
      if texel == 3 then return 0, 0, 0, 0 end
      local r, g, b = paletteColor(o.palette, base + texel)
      return r, g, b, 255
    elseif mode == 1 then -- 2 = mean(0,1); 3 transparent
      if texel == 3 then return 0, 0, 0, 0 end
      local r, g, b = blend(o.palette, base, base + 1, 1, 2)
      return r, g, b, 255
    elseif mode == 2 then -- all four explicit
      local r, g, b = paletteColor(o.palette, base + texel)
      return r, g, b, 255
    else -- mode 3: 2 = 5:3, 3 = 3:5
      local r, g, b
      if texel == 2 then r, g, b = blend(o.palette, base, base + 1, 5, 8)
      else r, g, b = blend(o.palette, base, base + 1, 3, 8) end
      return r, g, b, 255
    end
  end)
end

-- Scan the decoded RGBA8 byte string for alpha usage categories.
local function computeAlphaUsage(pixels)
  local hasZero, hasPartial, hasOpaque = false, false, false
  for i = 4, #pixels, 4 do
    local a = string.byte(pixels, i)
    if a == 0 then hasZero = true
    elseif a == 255 then hasOpaque = true
    else hasPartial = true end
  end
  return { hasZero = hasZero, hasPartial = hasPartial, hasOpaque = hasOpaque }
end

-- opts: { format, width, height, color0Transparent, texel, palette, indexData }.
-- Returns { width, height, pixels = rgba8 string, alphaUsage = {hasZero, hasPartial, hasOpaque} }.
function TextureDecoder.decode(opts, context)
  assert(type(opts) == "table", "TextureDecoder.decode requires an options table")
  local decoder = DECODERS[opts.format]
  if not decoder then
    if opts.format == 0 then
      error(Errors.new("NSBTX_FORMAT_NONE", "format 0 is 'no texture' and cannot be decoded",
        { format = 0, source = context }))
    end
    error(Errors.new("NSBTX_UNSUPPORTED_FORMAT",
      "unsupported texture format " .. tostring(opts.format),
      { format = opts.format, name = context and context.name, source = context }))
  end
  local pixels = decoder(opts)
  return {
    width = opts.width,
    height = opts.height,
    pixels = pixels,
    alphaUsage = computeAlphaUsage(pixels),
  }
end

TextureDecoder.SUPPORTED = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true }

return TextureDecoder
