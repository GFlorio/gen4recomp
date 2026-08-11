-- Pure Lua reference for the DS geometry-engine vertex-lighting calculation.
-- This is the same math the map vertex shader runs (shaders/map.glsl); the
-- two must agree exactly, and ds_lighting_test cross-checks them at midrange
-- values.
--
-- Authoritative formula: GBATEK "Internal Operation on Normal Command" --
--   VertexColor = Emission + Sum_i( LightColor_i * (Ambient +
--   Diffuse*ld + Specular*ls) )
-- summed per enabled light (polygon light mask) and per RGB channel. The
-- numeric domain follows the DS hardware (melonDS GPU3D::CalculateLighting):
-- colors are multiplied as fractions of full scale, not as saturating
-- integers, so a dim light dims a bright material proportionally. This
-- reference works in normalized 0..1 (RGB555 color / 31, fx12 vector / 4096)
-- and quantizes the clamped result to RGB555 with round-half-up, mirroring
-- the shader's quantizeRgb5. (The hardware truncates its fixed-point
-- accumulator instead, capping a single full-intensity light at 30/31;
-- round-half-up is the repo's chosen quantization and is what the shader
-- renders.)
--
-- The light vectors stored in HGSS profiles point in the direction the light
-- travels (from light source toward the surface). The diffuse factor is
-- max(0, -dot(L, N)). Specular uses the half-vector between the direction to
-- the light (-L) and the view direction V = (0, 0, 1) in camera/vector space.
-- When no shininess table is supplied the raw half-vector dot is used (exact
-- table lookup is deferred). Pure domain module: no love, arithmetic only.

local DsLighting = {}

-- The DS 5-bit numeric domain, owned here: RGB5/alpha5 channels span 0..31 and
-- fx12 vectors span 0..4096. Runtime consumers (MapRenderer, FieldActorDraw,
-- the loaders) reference these instead of repeating the literals; the GLSL
-- shader cannot share them and documents the same values in map.glsl.
DsLighting.RGB5_MAX = 31
DsLighting.FX12_SCALE = 4096
local VIEW_DIRECTION = { 0, 0, 1 }

local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

function DsLighting.unpackRgb555(packed)
  return packed % 32, math.floor(packed / 32) % 32, math.floor(packed / 1024) % 32
end

-- Unpack an RGB555 color to normalized 0..1 channel values.
local function unpackColor(packed)
  local r, g, b = DsLighting.unpackRgb555(packed)
  return { r / DsLighting.RGB5_MAX, g / DsLighting.RGB5_MAX, b / DsLighting.RGB5_MAX }
end

local function dot3(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
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

local function addInPlace(dst, src)
  dst[1] = dst[1] + src[1]
  dst[2] = dst[2] + src[2]
  dst[3] = dst[3] + src[3]
end

-- Clamp a normalized channel to [0, 1] and quantize to 5 bits, rounding
-- half-up exactly like the shader's quantizeRgb5.
local function quantize5(c)
  local clamped = c < 0 and 0 or (c > 1 and 1 or c)
  return math.floor(clamped * DsLighting.RGB5_MAX + 0.5)
end

-- Compute the lit RGB555 for one vertex. Colors are packed RGB555; lights use
-- the FieldLightProfile shape ({ enabled, colorRgb555, vectorFx12 }).
function DsLighting.vertexColorRgb5(params)
  local normal = normalize3(params.normal)
  local diffuse = unpackColor(params.diffuseRgb555)
  local ambient = unpackColor(params.ambientRgb555)
  local specular = unpackColor(params.specularRgb555)
  local emission = unpackColor(params.emissionRgb555)
  local lights = params.lights
  local lightMask = params.lightMask or 0
  local shininessTable = params.shininessTable

  local acc = { emission[1], emission[2], emission[3] }

  for i = 1, 4 do
    local bit = 2 ^ (i - 1)
    local light = lights[i]
    if light and light.enabled and (lightMask % (bit * 2) >= bit) then
      local L = normalize3({
        light.vectorFx12[1] / DsLighting.FX12_SCALE,
        light.vectorFx12[2] / DsLighting.FX12_SCALE,
        light.vectorFx12[3] / DsLighting.FX12_SCALE,
      })
      local ndl = dot3(L, normal)
      local ld = math.max(0, -ndl)

      local ls = 0
      if specular[1] > 0 or specular[2] > 0 or specular[3] > 0 then
        local H = normalize3({ -L[1] + VIEW_DIRECTION[1], -L[2] + VIEW_DIRECTION[2], -L[3] + VIEW_DIRECTION[3] })
        local ndh = math.max(0, dot3(normal, H))
        if shininessTable then
          ls = shininessTable.lookup and shininessTable.lookup(ndh) or ndh
        else
          ls = ndh
        end
      end

      local lcolor = unpackColor(light.colorRgb555)
      addInPlace(acc, {
        lcolor[1] * (ambient[1] + diffuse[1] * ld + specular[1] * ls),
        lcolor[2] * (ambient[2] + diffuse[2] * ld + specular[2] * ls),
        lcolor[3] * (ambient[3] + diffuse[3] * ld + specular[3] * ls),
      })
    end
  end

  return rgb555(quantize5(acc[1]), quantize5(acc[2]), quantize5(acc[3]))
end

-- DS 5-bit alpha composition. `At5` is the rounded texture alpha (0..31),
-- `Ap5` the polygon alpha (0..31). `polygonMode` is "modulation" or "decal".
function DsLighting.composeAlpha5(At5, Ap5, polygonMode)
  if polygonMode == "decal" then
    return Ap5
  end
  return math.floor((((At5 + 1) * (Ap5 + 1)) - 1) / 32)
end

return DsLighting
