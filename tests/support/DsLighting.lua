-- Pure Lua reference for the DS geometry-engine vertex-lighting calculation.
-- Test-support only: no love, arithmetic only. This module has no runtime
-- consumer -- GxRenderer/map.glsl implement the same sequencing directly in
-- GLSL, since lighting runs per vertex on the GPU -- so it exists purely as
-- an independent shader oracle for libs/nds/tests/love/ds_lighting_test.lua.
--
-- Authoritative source: melonDS-emu/melonDS, commit
-- d3cd6164deb1f217d4b262d18af3ef9b97e536c8, src/GPU3D.cpp,
-- GPU3D::CalculateLighting (plus the 0x21 NORMAL and 0x32 LIGHT_VECTOR
-- command handlers that feed its inputs). This is a literal transcription of
-- that function's integer sequencing, not a mathematically equivalent
-- continuous formula quantized only at the end:
--
--   vtxbuff[c] = MatEmission[c] << 14                      -- start, unnormalized
--   per enabled light i (polygon light mask bit i):
--     LightDirection[i] = -transform(storedDirection)        -- see below
--     dot = sum_c( (LightDirection[i][c] * normaltrans[c]) >> 9 )
--       -- the bottom 9 bits are discarded PER COMPONENT, before adding
--     if dot > 0:
--       diffdot = sign-extend(dot, 11 bits)
--       vtxbuff[c] += (MatDiffuse[c] * LightColor[i][c] * diffdot) & 0xFFFFF
--       specDot = sign-extend(dot + normaltrans.z, 11 bits)
--       squared = (specDot*specDot >> 10) & 0x3FF
--       den = LightDirection[i].z + (1 << 9)                 -- see SpecRecip note
--       SpecRecip = den == 0 and 0 or ((1 << 18) / den)
--       shinelevel = ((squared * SpecRecip) >> 8) - (1 << 9)
--       shinelevel = shinelevel < 0 and 0 or clamp(sign-extend(shinelevel, 14 bits), 0, 0x1FF)
--     else shinelevel = 0
--     vtxbuff[c] += ((MatSpecular[c] * shinelevel) + (MatAmbient[c] << 9)) * LightColor[i][c]
--       -- ambient is a plain <<9 shift, added for every enabled light
--       -- regardless of the diffuse gate; it is not scaled by diffuse level
--   VertexColor[c] = min(vtxbuff[c] >> 14, 31)               -- only clamp, at the very end
--
-- Domains: normals and the transformed light-direction register both live in
-- the geometry engine's 1.0.9 domain (NORMAL_FX_SCALE = 512 is 1.0, GBATEK
-- "Internal Operation on Normal Command"); material/light colors are 5-bit
-- (0..31, FixedPoint.RGB5_MAX).
--
-- LightDirection and the LIGHT_VECTOR command: GPU3D.cpp's case 0x32 handler
-- packs the command's raw direction argument in the same signed-10-bit/scale-
-- 512 domain as the NORMAL command, multiplies it through the current vector
-- matrix (discarding the matrix's own fixed-point scale), then negates and
-- sign-extends the result to 11 bits -- in that exact order ("discard bottom
-- 12 bits -> negate -> sign-extend"). This module's callers (GxRenderer /
-- map.glsl) supply the vector-matrix rotation upstream (the camera-only
-- rotation applied identically to the vertex normal, per GPU3D's vector
-- matrix being shared between NORMAL and LIGHT_VECTOR); this module receives
-- that already-rotated direction as plain floats and performs only the
-- negate/quantize/sign-extend steps downstream of it. A field-authored
-- `vectorFx12` is a continuous fx16-ish direction, not the hardware's
-- discrete 10-bit command argument or its rounding/overflow behavior; this
-- module does not reproduce that lost precision, only melonDS's arithmetic
-- from the (re-normalized) transformed direction onward, per this project's
-- documented host-space-normal-transform allowance.
--
-- SpecRecip: melonDS precomputes SpecRecip[i] = (1<<18) / den at LIGHT_VECTOR
-- command time, where den is the *pre-negation, pre-sign-extension* z
-- transform plus 512. Because this module's inputs are always unit vectors
-- (bounding the transformed z component to +-512), den can be recovered
-- losslessly from the already-computed, already-negated LightDirection.z
-- (den = LightDirection.z + 512) without keeping a separate intermediate --
-- unlike the raw hardware argument, our transformed direction never
-- overflows the 11-bit sign-extension in this domain, so the two
-- computations agree.
--
-- The shininess table (UseShininessTable, GPU3D.cpp shinelevel >>= 2;
-- ShininessTable[shinelevel]; shinelevel <<= 1) is not implemented: the HGSS
-- field render-state census (tests/rom/field_render_state_census_test.lua)
-- finds no compiled field material enabling it, and PolygonState's compiler
-- rejects a shininess-table polygon outright, so the runtime never needs the
-- lookup. The literal non-table shinelevel sequence above is unaffected by
-- that omission.

local FixedPoint = require("libs.math.src.FixedPoint")

local DsLighting = {}

-- 1.0.9 domain scale shared by normals, the transformed light-direction
-- register, and the derived diffuse/specular dot terms (GBATEK NORMAL
-- command: signed 10-bit components, unit length ~512).
DsLighting.NORMAL_FX_SCALE = 512

-- Field-authored light direction precision (fx16-ish, matching
-- FixedPoint.FX32_SCALE); only used to interpret vectorFx12 before
-- normalizing -- normalize() is scale-invariant, so this is documentation,
-- not a load-bearing divisor.
DsLighting.LIGHT_VECTOR_FX_SCALE = FixedPoint.FX32_SCALE

-- GPU3D.cpp integer domain widths used by CalculateLighting's masks/shifts.
local DIFFUSE_TERM_MODULUS = 0x100000 -- 20-bit mask (0xFFFFF + 1)
local SPEC_SQUARE_MODULUS = 0x400 -- 10-bit mask (0x3FF + 1)
local SPEC_RECIP_NUMERATOR = 0x40000 -- 1 << 18
local SPEC_SHINELEVEL_MAX = 0x1FF -- 9-bit clamp
local ACCUMULATOR_SHIFT = 0x4000 -- 1 << 14, final >> 14

local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

function DsLighting.unpackRgb555(packed)
  return packed % 32, math.floor(packed / 32) % 32, math.floor(packed / 1024) % 32
end

local function unpackColor5(packed)
  local r, g, b = DsLighting.unpackRgb555(packed)
  return { r, g, b }
end

local function length3(v)
  return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
end

local function normalize3(v)
  local len = length3(v)
  if len < 1e-12 then
    return { 0, 0, 0 }
  end
  return { v[1] / len, v[2] / len, v[3] / len }
end

-- Round a normalized float vector into an integer fixed-point domain,
-- matching how the geometry engine loads a normalized vector into a
-- fixed-point register (round to nearest, not truncate).
local function quantizeVector(v, scale)
  return {
    math.floor(v[1] * scale + 0.5),
    math.floor(v[2] * scale + 0.5),
    math.floor(v[3] * scale + 0.5),
  }
end

-- Reinterpret an integer as a two's-complement value of the given bit width
-- (GPU3D.cpp's `(x << (32 - bits)) >> (32 - bits)` sign-extension idiom).
local function signExtend(x, bits)
  local range = 2 ^ bits
  local wrapped = x % range
  if wrapped >= range / 2 then
    return wrapped - range
  end
  return wrapped
end

-- Dot product of two same-scale (NORMAL_FX_SCALE) fixed-point vectors, with
-- the bottom 9 bits of each per-component product discarded before summing
-- (GPU3D.cpp CalculateLighting: "bottom 9 bits are discarded after
-- multiplying and before adding" -- NOT the same as summing raw products and
-- shifting once).
local function dotDiscardingPerComponent(a, b, scale)
  local sum = 0
  for c = 1, 3 do
    sum = sum + math.floor((a[c] * b[c]) / scale)
  end
  return sum
end

-- Compute the lit RGB555 for one vertex. Colors are packed RGB555; lights use
-- the FieldLightProfile shape ({ enabled, colorRgb555, vectorFx12 }), whose
-- vector is expected already rotated into the same space as `normal` (see
-- module header). Every intermediate step below mirrors melonDS's literal
-- integer sequencing.
function DsLighting.vertexColorRgb5(params)
  local scale = DsLighting.NORMAL_FX_SCALE
  local normalFx9 = quantizeVector(normalize3(params.normal), scale)
  local diffuse5 = unpackColor5(params.diffuseRgb555)
  local ambient5 = unpackColor5(params.ambientRgb555)
  local specular5 = unpackColor5(params.specularRgb555)
  local emission5 = unpackColor5(params.emissionRgb555)
  local lights = params.lights
  local lightMask = params.lightMask or 0

  local acc = { emission5[1] * ACCUMULATOR_SHIFT, emission5[2] * ACCUMULATOR_SHIFT, emission5[3] * ACCUMULATOR_SHIFT }

  for i = 1, 4 do
    local bit = 2 ^ (i - 1)
    local light = lights[i]
    if light and light.enabled and (lightMask % (bit * 2) >= bit) then
      -- LightDirection[i]: the raw authored direction, normalized, then
      -- negated per the LIGHT_VECTOR command handler (GPU3D.cpp case 0x32).
      local direction = normalize3({
        light.vectorFx12[1] / DsLighting.LIGHT_VECTOR_FX_SCALE,
        light.vectorFx12[2] / DsLighting.LIGHT_VECTOR_FX_SCALE,
        light.vectorFx12[3] / DsLighting.LIGHT_VECTOR_FX_SCALE,
      })
      local lightDirectionFx9 = quantizeVector({ -direction[1], -direction[2], -direction[3] }, scale)

      local dot = dotDiscardingPerComponent(lightDirectionFx9, normalFx9, scale)

      local lightColor5 = unpackColor5(light.colorRgb555)
      local shinelevel = 0
      if dot > 0 then
        local diffdot = signExtend(dot, 11)
        for c = 1, 3 do
          acc[c] = acc[c] + (diffuse5[c] * lightColor5[c] * diffdot) % DIFFUSE_TERM_MODULUS
        end

        -- Specular reuses the diffuse dot, folds in the normal's Z (the DS
        -- geometry engine's fixed eye direction), truncate-squares it, then
        -- applies the light's precomputed reciprocal.
        local specDot = signExtend(dot + normalFx9[3], 11)
        local squared = math.floor((specDot * specDot) / 1024) % SPEC_SQUARE_MODULUS
        local den = lightDirectionFx9[3] + scale
        local specRecip = den == 0 and 0 or math.floor(SPEC_RECIP_NUMERATOR / den)
        shinelevel = math.floor((squared * specRecip) / 256) - scale
        if shinelevel < 0 then
          shinelevel = 0
        else
          shinelevel = signExtend(shinelevel, 14)
          if shinelevel < 0 then
            shinelevel = 0
          elseif shinelevel > SPEC_SHINELEVEL_MAX then
            shinelevel = SPEC_SHINELEVEL_MAX
          end
        end
      end

      for c = 1, 3 do
        acc[c] = acc[c] + ((specular5[c] * shinelevel) + (ambient5[c] * scale)) * lightColor5[c]
      end
    end
  end

  local r = math.min(math.floor(acc[1] / ACCUMULATOR_SHIFT), FixedPoint.RGB5_MAX)
  local g = math.min(math.floor(acc[2] / ACCUMULATOR_SHIFT), FixedPoint.RGB5_MAX)
  local b = math.min(math.floor(acc[3] / ACCUMULATOR_SHIFT), FixedPoint.RGB5_MAX)
  return rgb555(r, g, b)
end

return DsLighting
