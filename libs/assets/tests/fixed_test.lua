-- Boundary tests for the Nitro fixed-point/packed-value helpers. Signed
-- extension is checked at min/max/-1 for each width, plus the color and angle
-- conversions at their range ends.

local Assert = require("tests.support.Assert")
local Fixed = require("libs.assets.src.nitro.Fixed")

local T = {}

function T.fx32_boundaries()
  Assert.equal(Fixed.fx32(0), 0)
  Assert.equal(Fixed.fx32(4096), 1)
  Assert.equal(Fixed.fx32(0xFFFFFFFF), -1 / 4096) -- -1 raw
  Assert.equal(Fixed.fx32(0x80000000), -2 ^ 31 / 4096) -- most negative
  Assert.equal(Fixed.fx32(0x7FFFFFFF), (2 ^ 31 - 1) / 4096) -- most positive
end

function T.fx16_boundaries()
  Assert.equal(Fixed.fx16(0), 0)
  Assert.equal(Fixed.fx16(4096), 1)
  Assert.equal(Fixed.fx16(0xFFFF), -1 / 4096)
  Assert.equal(Fixed.fx16(0x8000), -8) -- -32768/4096
  Assert.equal(Fixed.fx16(0x7FFF), 32767 / 4096)
end

function T.s10_boundaries()
  Assert.equal(Fixed.s10(0), 0)
  Assert.equal(Fixed.s10(1), 1)
  Assert.equal(Fixed.s10(511), 511)
  Assert.equal(Fixed.s10(512), -512)
  Assert.equal(Fixed.s10(1023), -1)
end

function T.normal10_unpacks_three_components()
  -- x=511 (max +), y=512 (-512), z=1 packed at 0/10/20 bit fields.
  local word = 511 + 512 * 1024 + 1 * 1048576
  local nx, ny, nz = Fixed.normal10(word)
  Assert.equal(nx, 511 / 512)
  Assert.equal(ny, -1)
  Assert.equal(nz, 1 / 512)
end

function T.rgb555_range_ends()
  local r, g, b = Fixed.rgb555(0)
  Assert.equal(r, 0); Assert.equal(g, 0); Assert.equal(b, 0)
  r, g, b = Fixed.rgb555(0x7FFF) -- all 5-bit fields set
  Assert.equal(r, 255); Assert.equal(g, 255); Assert.equal(b, 255)
  -- pure red (r5=31), high bit set must not leak into blue.
  r, g, b = Fixed.rgb555(0x801F)
  Assert.equal(r, 255); Assert.equal(g, 0); Assert.equal(b, 0)
end

function T.angle16_range()
  Assert.equal(Fixed.angle16(0), 0)
  Assert.equal(Fixed.angle16(16384), math.pi / 2)
  Assert.equal(Fixed.angle16(32768), math.pi)
end

return T
