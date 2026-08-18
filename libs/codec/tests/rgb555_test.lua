-- RGB555 channel order tests. Tests decoding of Nintendo DS RGB555
-- (red bits 0..4, green bits 5..9, blue bits 10..14) to 8-bit sRGB.
-- Canonical source: pret/pokeheartgold, lib/include/nitro/gx/gxcommon.h

local Assert = require("tests.support.Assert")
local Rgb555 = require("libs.codec.src.Rgb555")

local T = {
  metadata = {
    capabilities = {},
  },
  tests = {},
}

local function expand5(value)
  return math.floor((value * 255 + 15) / 31)
end

-- Exact test vectors for standard primary colors and mixed values
function T.tests.decodes_black()
  local result = Rgb555.decode(0x0000)
  Assert.equal(result.r, 0)
  Assert.equal(result.g, 0)
  Assert.equal(result.b, 0)
end

function T.tests.decodes_red()
  local result = Rgb555.decode(0x001F)
  Assert.equal(result.r, 255)
  Assert.equal(result.g, 0)
  Assert.equal(result.b, 0)
end

function T.tests.decodes_green()
  local result = Rgb555.decode(0x03E0)
  Assert.equal(result.r, 0)
  Assert.equal(result.g, 255)
  Assert.equal(result.b, 0)
end

function T.tests.decodes_blue()
  local result = Rgb555.decode(0x7C00)
  Assert.equal(result.r, 0)
  Assert.equal(result.g, 0)
  Assert.equal(result.b, 255)
end

function T.tests.decodes_white()
  local result = Rgb555.decode(0x7FFF)
  Assert.equal(result.r, 255)
  Assert.equal(result.g, 255)
  Assert.equal(result.b, 255)
end

-- Bit 15 ignored by channel extraction
function T.tests.ignores_bit15_on_red()
  local result = Rgb555.decode(0x801F)
  Assert.equal(result.r, 255)
  Assert.equal(result.g, 0)
  Assert.equal(result.b, 0)
end

-- Mixed value that exposes R/B swap: amber/gold color (used in HGSS signpost palettes)
-- RGB555: r=0x1F (31=255), g=0x14 (20≈160), b=0x00 (0=0) = gold/amber
function T.tests.decodes_mixed_amber_not_inverted()
  local r5 = 0x1F
  local g5 = 0x14
  local b5 = 0x00
  local word = r5 + (g5 * 32) + (b5 * 1024)

  local result = Rgb555.decode(word)
  Assert.equal(result.r, 255, "amber red channel must be 255")
  Assert.equal(result.g, expand5(20), "amber green channel must be 160-ish")
  Assert.equal(result.b, 0, "amber blue channel must be 0")
end

-- Additional test with all channels present to detect systematic swap
-- RGB555: r=0x10 (16≈82), g=0x12 (18≈92), b=0x14 (20≈102)
function T.tests.decodes_mixed_channels_correctly()
  local r5 = 0x10
  local g5 = 0x12
  local b5 = 0x14
  local word = r5 + (g5 * 32) + (b5 * 1024)

  local result = Rgb555.decode(word)
  local expectedR = expand5(r5)
  local expectedG = expand5(g5)
  local expectedB = expand5(b5)

  Assert.equal(result.r, expectedR, "red channel incorrect")
  Assert.equal(result.g, expectedG, "green channel incorrect")
  Assert.equal(result.b, expectedB, "blue channel incorrect")
end

return T
