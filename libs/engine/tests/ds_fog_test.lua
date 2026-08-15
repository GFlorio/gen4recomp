-- Pure reference contract for DS GX fog, following the same style as
-- DsFragment/DsBlend/DsDepth: no love dependency, arithmetic only,
-- GBATEK-level reconstruction (not yet verified against melonDS source,
-- consistent with DsDepth's disclosed scope cut -- whoever tightens fog
-- precision further should re-check against melonDS before relying on exact
-- density/table precision).
--
-- Authoritative source: GBATEK "3D Display - Fog and Fog Table". The 32-entry
-- fog density table holds 7-bit densities (0..127, 127 == fully fogged); an
-- out-of-range depth index clamps to the table's first/last entry rather than
-- wrapping or extrapolating. Fog only affects a fragment when BOTH the
-- global DISP3DCNT fog-enable bit and the fragment's polygon FOG_ENABLE
-- attribute bit are set -- neither gate alone is sufficient.

local Assert = require("tests.support.Assert")
local DsFog = require("libs.engine.src.DsFog")

local T = {}

local function table32(fill)
  local t = {}
  for i = 0, 31 do
    t[i] = fill(i)
  end
  return t
end

-- densityAt indexes the 32-entry table directly and clamps out-of-range
-- indices to the nearest real entry (index 0 or 31), never wrapping.
function T.density_at_indexes_and_clamps_the_32_entry_table()
  local ramp = table32(function(i)
    return i * 4
  end)
  Assert.equal(DsFog.densityAt(ramp, 0), 0)
  Assert.equal(DsFog.densityAt(ramp, 31), 124)
  Assert.equal(DsFog.densityAt(ramp, -1), 0, "a before-range index clamps to entry 0")
  Assert.equal(DsFog.densityAt(ramp, 32), 124, "an after-range index clamps to entry 31")
end

-- density 0 leaves the fragment untouched; density 127 (fully fogged)
-- replaces it outright with the fog color; intermediate densities blend
-- proportionally, matching DsBlend's truncating-divide style.
function T.blend_color_interpolates_by_density_out_of_127()
  local fragment = { 60, 20, 0 }
  local fogColor = { 0, 0, 60 }
  Assert.deepEqual(DsFog.blendColor(fragment, fogColor, 0), { 60, 20, 0 })
  Assert.deepEqual(DsFog.blendColor(fragment, fogColor, 127), { 0, 0, 60 })
  local half = DsFog.blendColor(fragment, fogColor, 64)
  -- floor((60*(127-64) + 0*64)/127), etc. -- a truncating divide like every
  -- other DS reference module in this codebase (DsFragment, DsBlend).
  Assert.deepEqual(half, {
    math.floor((60 * (127 - 64) + 0 * 64) / 127),
    math.floor((20 * (127 - 64) + 0 * 64) / 127),
    math.floor((0 * (127 - 64) + 60 * 64) / 127),
  })
end

-- Fog only applies with both gates set: the global DISP3DCNT fog-enable bit
-- and the fragment's own polygon FOG_ENABLE attribute.
function T.applies_requires_both_the_global_and_per_polygon_gate()
  Assert.isTrue(DsFog.applies(true, true))
  Assert.isFalse(DsFog.applies(true, false), "polygon fogEnabled=false must not fog even if globally enabled")
  Assert.isFalse(DsFog.applies(false, true), "a globally disabled fog pass must not fog any polygon")
  Assert.isFalse(DsFog.applies(false, false))
end

return { tests = T }
