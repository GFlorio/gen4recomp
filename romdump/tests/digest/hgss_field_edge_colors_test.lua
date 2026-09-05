-- Tests for HgssFieldEdgeColors: the two real HGSS field edge-color tables
-- (ov01_02208BA0 / ov01_02208BB0) and the per-area selector byte that picks
-- between them. Source: pret/pokeheartgold overlay_01_021FB878.s.

local Assert = require("tests.support.Assert")
local HgssFieldEdgeColors = require("romdump.src.digest.field.HgssFieldEdgeColors")

local T = {}

local BLACK = 0
local GREY_4_4_4 = 4 + 4 * 32 + 4 * 1024

local function decodeRgb555(value)
  return value % 32, math.floor(value / 32) % 32, math.floor(value / 1024)
end

function T.table_a_is_black_at_zero_and_grey_elsewhere()
  local a = HgssFieldEdgeColors.TABLE_A
  Assert.equal(a[0], BLACK)
  for i = 1, 7 do
    Assert.equal(a[i], GREY_4_4_4, "entry " .. i)
  end
end

function T.table_b_is_uniformly_grey()
  local b = HgssFieldEdgeColors.TABLE_B
  for i = 0, 7 do
    Assert.equal(b[i], GREY_4_4_4, "entry " .. i)
  end
end

function T.tables_have_exactly_eight_zero_based_entries()
  for _, t in ipairs({ HgssFieldEdgeColors.TABLE_A, HgssFieldEdgeColors.TABLE_B }) do
    local count = 0
    for i = 0, 7 do
      Assert.notNil(t[i], "entry " .. i)
      count = count + 1
    end
    Assert.isNil(t[8], "no entry 8")
    Assert.equal(count, 8)
  end
end

function T.selector_picks_table_a_only_on_zero()
  Assert.equal(HgssFieldEdgeColors.tableForAreaLightPattern(0), HgssFieldEdgeColors.TABLE_A)
  Assert.equal(HgssFieldEdgeColors.tableForAreaLightPattern(1), HgssFieldEdgeColors.TABLE_B)
  Assert.equal(HgssFieldEdgeColors.tableForAreaLightPattern(2), HgssFieldEdgeColors.TABLE_B)
  Assert.equal(HgssFieldEdgeColors.tableForAreaLightPattern(9), HgssFieldEdgeColors.TABLE_B)
end

function T.selector_rejects_invalid_input()
  Assert.throws(function()
    HgssFieldEdgeColors.tableForAreaLightPattern(-1)
  end)
  Assert.throws(function()
    HgssFieldEdgeColors.tableForAreaLightPattern(1.5)
  end)
end

function T.packed_values_decode_to_raw_decomp_bytes()
  local r, g, b = decodeRgb555(HgssFieldEdgeColors.TABLE_A[0])
  Assert.equal(r, 0)
  Assert.equal(g, 0)
  Assert.equal(b, 0)

  r, g, b = decodeRgb555(HgssFieldEdgeColors.TABLE_A[1])
  Assert.equal(r, 4)
  Assert.equal(g, 4)
  Assert.equal(b, 4)

  r, g, b = decodeRgb555(HgssFieldEdgeColors.TABLE_B[0])
  Assert.equal(r, 4)
  Assert.equal(g, 4)
  Assert.equal(b, 4)
end

return { tests = T }
