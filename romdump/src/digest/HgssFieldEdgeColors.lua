-- HGSS's two real field edge-color tables and the per-area selector between
-- them, recovered from pret/pokeheartgold asm/overlay_01_021FB878.s.
--
-- AreaDataManager_Load reads a byte at AreaDataManager+0x8B7 and calls
-- G3X_SetEdgeColorTable with ov01_02208BA0 (ROM 0x02208BA0) when that byte is
-- zero, or ov01_02208BB0 (ROM 0x02208BB0) otherwise. The same byte is read by
-- AreaDataManager_GetAreaLightArchiveID as a small enum (0/1/2/other), which
-- confirms it is a per-area "light pattern index", not a boolean; only
-- zero-vs-non-zero matters for edge-color selection. The byte lives at offset
-- +7 within a per-area record that AreaDataManager_Alloc reads from NARC
-- member id 0x2a, keyed by the caller's areaDataBank -- it is genuinely
-- per-area ROM data, not a global constant.
--
-- Each table holds 8 RGB555 halfwords, indexed by centerPolygonId >> 3.
-- Packing convention (matches HgssFieldLightProfile.rgb555): value = r + g*32
-- + b*1024, each channel 0-31.
--
-- Raw bytes transcribed from overlay_01_021FB878.s .rodata:
--   ov01_02208BA0: 00 00 84 10 84 10 84 10 84 10 84 10 84 10 84 10
--   ov01_02208BB0: 84 10 84 10 84 10 84 10 84 10 84 10 84 10 84 10
-- 0x0000 decodes to (0,0,0); 0x1084 decodes to (4,4,4).

local HgssFieldEdgeColors = {}

local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

local BLACK = rgb555(0, 0, 0)
local GREY = rgb555(4, 4, 4)

-- ov01_02208BA0: index 0 is black, indices 1-7 are grey(4,4,4).
local TABLE_A = { [0] = BLACK, GREY, GREY, GREY, GREY, GREY, GREY, GREY }

-- ov01_02208BB0: all eight entries are grey(4,4,4).
local TABLE_B = { [0] = GREY, GREY, GREY, GREY, GREY, GREY, GREY, GREY }

HgssFieldEdgeColors.TABLE_A = TABLE_A
HgssFieldEdgeColors.TABLE_B = TABLE_B

-- Mirrors AreaDataManager_Load's edge-color-table branch on the byte at
-- AreaDataManager+0x8B7: zero selects TABLE_A, any other value selects
-- TABLE_B.
---@param lightPatternIndex number non-negative per-area light pattern byte
---@return integer[]
function HgssFieldEdgeColors.tableForAreaLightPattern(lightPatternIndex)
  assert(
    type(lightPatternIndex) == "number"
      and lightPatternIndex == math.floor(lightPatternIndex)
      and lightPatternIndex >= 0,
    "lightPatternIndex must be a non-negative integer"
  )
  if lightPatternIndex == 0 then
    return TABLE_A
  end
  return TABLE_B
end

return HgssFieldEdgeColors
