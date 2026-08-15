-- Pure Lua reference for the DS GPU3D fog contract: the 32-entry fog-density
-- table lookup, the fog color blend, and the two-gate fog-enable predicate.
-- No love dependency, arithmetic only.
--
-- Authoritative source: GBATEK "3D Display - Fog and Fog Table" (GX_g3x.c's
-- G3X_SetFog/G3X_SetFogTable register layout confirms the mechanism; see
-- tmp/refs/pokediamond/arm9/lib/NitroSDK/src/GX_g3x.c and
-- tmp/refs/pokeheartgold/lib/include/nitro/gx/g3x.h). Like DsDepth, this is a
-- GBATEK-level reconstruction, not yet verified against melonDS source --
-- whoever tightens fog precision further should re-check against melonDS.
--
-- The 32-entry density table holds 7-bit densities (0..127, 127 == fully
-- fogged); an out-of-range depth index clamps to the table's first/last
-- entry rather than wrapping or extrapolating -- the hardware fog unit reads
-- one of exactly 32 registers, so there is no entry to wrap or extrapolate
-- to. Fog only affects a fragment when BOTH the global DISP3DCNT fog-enable
-- bit and the fragment's own polygon FOG_ENABLE attribute bit
-- (DsPolygonAttr.fogEnabled) are set -- neither gate alone is sufficient.

local DsFog = {}

-- Index the 32-entry density table, clamping an out-of-range index to entry
-- 0 or 31 rather than wrapping.
function DsFog.densityAt(table32, index)
  local clamped = index
  if clamped < 0 then
    clamped = 0
  elseif clamped > 31 then
    clamped = 31
  end
  return table32[clamped]
end

-- Blend a fragment's RGB toward the fog color by `density` out of 127
-- (0 = untouched, 127 = fully replaced), truncating divide like every other
-- DS reference module in this codebase (DsFragment, DsBlend).
function DsFog.blendColor(fragmentRgb, fogColorRgb, density)
  local out = {}
  for i = 1, 3 do
    out[i] = math.floor((fragmentRgb[i] * (127 - density) + fogColorRgb[i] * density) / 127)
  end
  return out
end

-- Fog applies to a fragment only when both the global DISP3DCNT fog-enable
-- bit and the fragment's own polygon FOG_ENABLE attribute are set.
function DsFog.applies(globalEnabled, polygonEnabled)
  return globalEnabled == true and polygonEnabled == true
end

return DsFog
