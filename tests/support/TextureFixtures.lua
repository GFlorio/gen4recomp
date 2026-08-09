-- Byte-level fixtures for Nitro texture tests: BGR555 palette assembly, packed
-- index encoders, and a few named colors. Keeps decoder tests exact without
-- committing real texture art.

local TextureFixtures = {}

function TextureFixtures.u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

-- Named BGR555 primaries (high alpha bit clear).
TextureFixtures.BLACK = 0x0000
TextureFixtures.RED = 0x001F
TextureFixtures.GREEN = 0x03E0
TextureFixtures.BLUE = 0x7C00
TextureFixtures.WHITE = 0x7FFF

-- Palette string from a list of BGR555 u16 values.
function TextureFixtures.palette(values)
  local out = {}
  for _, v in ipairs(values) do
    out[#out + 1] = TextureFixtures.u16(v)
  end
  return table.concat(out)
end

-- Default 4-entry palette: index 0 black, 1 red, 2 green, 3 blue.
function TextureFixtures.primaryPalette()
  return TextureFixtures.palette({
    TextureFixtures.BLACK,
    TextureFixtures.RED,
    TextureFixtures.GREEN,
    TextureFixtures.BLUE,
  })
end

-- Pack a flat array of 2-bit indices, 4 per byte, LSB first.
function TextureFixtures.pack2(indices)
  local out = {}
  for i = 1, #indices, 4 do
    local b = 0
    for j = 0, 3 do
      local v = indices[i + j] or 0
      b = b + v * (4 ^ j)
    end
    out[#out + 1] = string.char(b)
  end
  return table.concat(out)
end

-- Pack a flat array of 4-bit indices, 2 per byte, low nibble first.
function TextureFixtures.pack4(indices)
  local out = {}
  for i = 1, #indices, 2 do
    local lo = indices[i] or 0
    local hi = indices[i + 1] or 0
    out[#out + 1] = string.char(lo + hi * 16)
  end
  return table.concat(out)
end

-- The four RGBA bytes of pixel (x, y) in an RGBA8 string of the given width.
function TextureFixtures.pixel(pixels, width, x, y)
  local off = (y * width + x) * 4
  return string.byte(pixels, off + 1, off + 4)
end

return TextureFixtures
