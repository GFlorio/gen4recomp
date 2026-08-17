-- Pure Lua reference for the DS GPU's per-pixel fog density and blend
-- equations. Test-support only: no love, arithmetic only. This module has no
-- runtime consumer -- the final full-screen shader (currently
-- libs/engine/src/shaders/edge.glsl) implements the same sequencing directly
-- in GLSL, since fog runs per fragment on the GPU -- so it exists purely as
-- an independent shader oracle for libs/engine/tests/ds_fog_test.lua.
--
-- Authoritative source: melonDS-emu/melonDS, commit
-- d3cd6164deb1f217d4b262d18af3ef9b97e536c8, src/GPU3D_Soft.cpp,
-- SoftRenderer3D::CalculateFogDensity, and src/GPU3D.cpp's
-- `RenderFogOffset = FogOffset * 0x200` latch. This is a literal
-- transcription of that function's integer sequencing:
--
--   renderFogOffset = fogOffsetRaw * 0x200
--   if z < renderFogOffset:
--     densityId, densityFrac = 0, 0
--   else:
--     z = z - renderFogOffset
--     z = (z >> 2) << fogShift
--     densityId = z >> 17
--     if densityId >= 32:
--       densityId, densityFrac = 32, 0
--     else:
--       densityFrac = z & 0x1FFFF
--   density = (expanded[densityId] * (0x20000 - densityFrac)
--              + expanded[densityId + 1] * densityFrac) >> 17
--   if density >= 127: density = 128
--
-- where `expanded` is the caller's 32-entry density table with both
-- endpoints duplicated once (expanded[0] = table[0], expanded[33] =
-- table[31]), so a densityId of 0 or 32 always has a defined neighbor to
-- interpolate against. Because every valid densityId (0..32) maps to a
-- 1-indexed Lua `table32` position by simply clamping to [1, 32], expanded
-- lookup and endpoint duplication collapse into one clamp -- see
-- `expandedEntry` below.
--
-- `z` (the function's sole numeric input besides the offset/shift/table) is
-- the renderer's `dsWbufferDepth` quantized value -- a camera.far-normalized
-- proxy for real DS W-buffer depth, not an exact reproduction of it (see
-- libs/engine/src/shaders/map.glsl's dsWbufferDepth header and
-- docs/rendering.md's approximate-features table for why an exact
-- per-polygon W-buffer scale cannot be established without a full DS
-- fixed-point geometry-engine emulation). This module only reproduces the
-- density/blend arithmetic that consumes that proxy; it takes no position on
-- what the proxy itself should be.
--
-- The final RGB/alpha blend (SoftRenderer3D::RenderPixel's post-density
-- step) divides by 128 (density is 0..128), not 127:
--
--   outComponent = (fogComponent * density + srcComponent * (128 - density)) >> 7

local DsFog = {}

-- expanded[idx] for idx in 0..33, given a 1-indexed 32-entry Lua table
-- (table32[1] == source byte 0 .. table32[32] == source byte 31). Endpoint
-- duplication (expanded[0]==expanded[1]==source[0], expanded[32]==
-- expanded[33]==source[31]) falls out of clamping idx into [1, 32] directly.
local function expandedEntry(table32, idx)
  local clamped = idx
  if clamped < 1 then
    clamped = 1
  elseif clamped > 32 then
    clamped = 32
  end
  return table32[clamped]
end

-- `z`: the fragment's dsWbufferDepth-domain quantized depth (see module
-- header). `fogOffsetRaw`: the preset's raw G3X FOG_OFFSET field, not yet
-- multiplied by 0x200. `fogShift`: the preset's slope field, used directly as
-- the RenderFogShift exponent. `table32`: the preset's 32-entry raw density
-- bytes (0..255), 1-indexed.
---@param z number
---@param fogOffsetRaw number
---@param fogShift number
---@param table32 number[]
---@return integer density 0..128
function DsFog.density(z, fogOffsetRaw, fogShift, table32)
  local renderFogOffset = fogOffsetRaw * 0x200
  local densityId, densityFrac
  if z < renderFogOffset then
    densityId, densityFrac = 0, 0
  else
    local shifted = math.floor((z - renderFogOffset) / 4) * (2 ^ fogShift)
    densityId = math.floor(shifted / 131072)
    if densityId >= 32 then
      densityId, densityFrac = 32, 0
    else
      densityFrac = shifted - densityId * 131072
    end
  end
  local lo = expandedEntry(table32, densityId)
  local hi = expandedEntry(table32, densityId + 1)
  local density = math.floor((lo * (131072 - densityFrac) + hi * densityFrac) / 131072)
  if density >= 127 then
    density = 128
  end
  return density
end

-- One RGB (or alpha) component's fog blend, in the DS's native domain: a
-- 6-bit (0..63) RGB component or a 5-bit (0..31) alpha component, blended by
-- `density` (0..128) with a truncating divide by 128 -- not 127.
---@param component number the pre-fog fragment component (any domain)
---@param fogComponent number the fog preset's component, same domain
---@param density integer 0..128
---@return integer
function DsFog.blend(component, fogComponent, density)
  return math.floor((fogComponent * density + component * (128 - density)) / 128)
end

-- 5-bit (0..31) RGB555 component -> the DS six-bit framebuffer domain
-- (melonDS GPU3D_Soft.cpp color conversion, locked in deliverable A/expand5to6):
-- 0 stays 0, any non-zero n becomes 2n+1. Fog color enters the same 6-bit
-- combiner domain every other color in the pipeline does -- never a raw /31
-- normalization.
---@param c5 number
---@return integer
function DsFog.expand5to6(c5)
  if c5 <= 0 then
    return 0
  end
  return c5 * 2 + 1
end

return DsFog
