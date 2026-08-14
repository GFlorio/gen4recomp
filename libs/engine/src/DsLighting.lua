-- Pure Lua reference for the DS geometry-engine vertex-lighting calculation.
-- Pure domain module: no love, arithmetic only.
--
-- Authoritative formula: GBATEK "Internal Operation on Normal Command" --
--   VertexColor = Emission + Sum_i( LightColor_i * (Ambient +
--   Diffuse*ld + Specular*ls) )
-- summed per enabled light (polygon light mask) and per RGB channel.
--
-- Unlike an earlier version of this module, the pipeline below works in the
-- DS hardware's own fixed-point domains and truncates at each step (melonDS
-- GPU3D::CalculateLighting's sequencing), not merely a mathematically
-- equivalent continuous formula quantized only at the end. Normal vectors
-- live in the geometry engine's 1.0.9 domain (NORMAL_FX_SCALE = 512 is 1.0);
-- light direction vectors live in its 1.3.12 domain (LIGHT_VECTOR_FX_SCALE =
-- 4096 is 1.0, matching libs.math.FixedPoint.FX32_SCALE); material/light
-- colors are 5-bit (0..31, FixedPoint.RGB5_MAX). Vector *normalization*
-- itself (this module's inputs may arrive as post-transform floats) is done
-- with real division/sqrt -- the geometry engine's own normalize microcode
-- is not reverse-engineered here, only the truncation-bearing steps
-- downstream of it: dot products, per-term multiplies, the specular square,
-- the per-light sum, and the final saturating accumulator.
--
-- Truncation pipeline, per enabled light:
--   1. Quantize the normalized normal/light-direction vectors into their
--      fixed-point domains (round to nearest, matching how the geometry
--      engine loads a normalized vector into a fixed register).
--   2. Dot product truncates toward -infinity when descaling (floor(raw /
--      4096), matching a hardware arithmetic right shift), landing back in
--      the normal's 1.0.9 domain. `ld` (diffuse level) is the negated,
--      front-light-gated dot: max(0, -dot(L,N)), same domain (0..512).
--   3. Specular is only evaluated when ld > 0 (the melonDS front-light
--      gate). The half vector H = normalize(-L+V) is likewise quantized to
--      1.0.9, dotted with the normal the same truncating way to get `ndh`
--      (0..512), then truncate-squared back into the 1.0.9 domain
--      (floor(ndh*ndh/512)) before the cos(2a)-equivalent doubling:
--      ls = clamp(2*ndhSquared - 512, 0, 512).
--   4. Each material term (diffuse*ld, specular*ls) truncates its own
--      product before joining the (ungated) ambient term: termSum = ambient
--      + floor(diffuse*ld/512) + floor(specular*ls/512). Ambient never
--      passes through ld/ls at all -- melonDS adds it for every enabled
--      light regardless of the light/normal dot.
--   5. The light color scales that per-channel sum, truncating again:
--      floor(lightColor*termSum/31).
--   6. Contributions from every enabled light and the emission register sum
--      as plain integers; only the *final* accumulator saturates to 0..31
--      (RGB5_MAX) -- no per-light or per-term clamp.
--
-- The light vectors stored in HGSS profiles point in the direction the light
-- travels (from light source toward the surface).

local FixedPoint = require("libs.math.src.FixedPoint")

local DsLighting = {}

-- 1.0.9 domain scale for normals and the derived diffuse/specular levels
-- (GBATEK NORMAL command: signed 10-bit components, unit length ~512).
DsLighting.NORMAL_FX_SCALE = 512

-- 1.3.12 domain scale for light direction vectors, shared with
-- FixedPoint.FX32_SCALE (fx16/fx32 words).
DsLighting.LIGHT_VECTOR_FX_SCALE = FixedPoint.FX32_SCALE

local VIEW_DIRECTION = { 0, 0, 1 }

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

-- Dot product of two same-scale fixed-point vectors, truncated (floor,
-- matching a hardware arithmetic right shift) back into that same scale's
-- domain: floor((ax*bx+ay*by+az*bz) / scale).
local function dotFxSameScale(a, b, scale)
  return math.floor((a[1] * b[1] + a[2] * b[2] + a[3] * b[3]) / scale)
end

-- Dot product of a 1.0.9 vector and a 1.3.12 vector, truncated into the
-- 1.0.9 domain: floor(raw / LIGHT_VECTOR_FX_SCALE).
local function dotNormalLight(normalFx9, lightFx12)
  return math.floor(
    (normalFx9[1] * lightFx12[1] + normalFx9[2] * lightFx12[2] + normalFx9[3] * lightFx12[3])
      / DsLighting.LIGHT_VECTOR_FX_SCALE
  )
end

local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

-- Compute the lit RGB555 for one vertex. Colors are packed RGB555; lights use
-- the FieldLightProfile shape ({ enabled, colorRgb555, vectorFx12 }). Truncates
-- at each fixed-point step per this module's header; see there for the domains.
function DsLighting.vertexColorRgb5(params)
  local normalFx9 = quantizeVector(normalize3(params.normal), DsLighting.NORMAL_FX_SCALE)
  local diffuse5 = unpackColor5(params.diffuseRgb555)
  local ambient5 = unpackColor5(params.ambientRgb555)
  local specular5 = unpackColor5(params.specularRgb555)
  local emission5 = unpackColor5(params.emissionRgb555)
  local lights = params.lights
  local lightMask = params.lightMask or 0

  local acc = { emission5[1], emission5[2], emission5[3] }

  for i = 1, 4 do
    local bit = 2 ^ (i - 1)
    local light = lights[i]
    if light and light.enabled and (lightMask % (bit * 2) >= bit) then
      local lightFx12 = quantizeVector(
        normalize3({
          light.vectorFx12[1] / DsLighting.LIGHT_VECTOR_FX_SCALE,
          light.vectorFx12[2] / DsLighting.LIGHT_VECTOR_FX_SCALE,
          light.vectorFx12[3] / DsLighting.LIGHT_VECTOR_FX_SCALE,
        }),
        DsLighting.LIGHT_VECTOR_FX_SCALE
      )

      local dot9 = dotNormalLight(normalFx9, lightFx12)
      local ld = clamp(-dot9, 0, DsLighting.NORMAL_FX_SCALE)

      -- Specular is the melonDS cos(2a) term behind its front-light gate
      -- (ld > 0, GPU3D.cpp CalculateLighting): ls = clamp(2*ndh^2 - 1, 0, 1)
      -- in continuous terms, computed here as a truncated 1.0.9-domain square.
      local ls = 0
      if ld > 0 then
        local halfFx9 = quantizeVector(
          normalize3({
            -lightFx12[1] / DsLighting.LIGHT_VECTOR_FX_SCALE + VIEW_DIRECTION[1],
            -lightFx12[2] / DsLighting.LIGHT_VECTOR_FX_SCALE + VIEW_DIRECTION[2],
            -lightFx12[3] / DsLighting.LIGHT_VECTOR_FX_SCALE + VIEW_DIRECTION[3],
          }),
          DsLighting.NORMAL_FX_SCALE
        )
        local ndh = clamp(dotFxSameScale(normalFx9, halfFx9, DsLighting.NORMAL_FX_SCALE), 0, DsLighting.NORMAL_FX_SCALE)
        local ndhSquared = math.floor((ndh * ndh) / DsLighting.NORMAL_FX_SCALE)
        ls = clamp(2 * ndhSquared - DsLighting.NORMAL_FX_SCALE, 0, DsLighting.NORMAL_FX_SCALE)
      end

      local lightColor5 = unpackColor5(light.colorRgb555)
      for c = 1, 3 do
        local diffuseTerm = math.floor((diffuse5[c] * ld) / DsLighting.NORMAL_FX_SCALE)
        local specularTerm = math.floor((specular5[c] * ls) / DsLighting.NORMAL_FX_SCALE)
        local termSum = ambient5[c] + diffuseTerm + specularTerm
        acc[c] = acc[c] + math.floor((lightColor5[c] * termSum) / FixedPoint.RGB5_MAX)
      end
    end
  end

  return rgb555(
    clamp(acc[1], 0, FixedPoint.RGB5_MAX),
    clamp(acc[2], 0, FixedPoint.RGB5_MAX),
    clamp(acc[3], 0, FixedPoint.RGB5_MAX)
  )
end

return DsLighting
