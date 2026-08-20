-- Conversion from Nintendo DS RGB555 (red bits 0..4, green bits 5..9, blue bits
-- 10..14) to 8-bit sRGB. Canonical source: pret/pokeheartgold,
-- lib/include/nitro/gx/gxcommon.h

local Rgb555 = {}

local function expand5(value)
  return math.floor((value * 255 + 15) / 31)
end

---@param word integer
---@return { r: integer, g: integer, b: integer }
function Rgb555.decode(word)
  assert(
    type(word) == "number" and word % 1 == 0 and word >= 0 and word <= 0xFFFF,
    "RGB555 word must be an unsigned 16-bit integer"
  )

  local r5 = word % 32
  local g5 = math.floor(word / 32) % 32
  local b5 = math.floor(word / 1024) % 32

  return {
    r = expand5(r5),
    g = expand5(g5),
    b = expand5(b5),
  }
end

return Rgb555
