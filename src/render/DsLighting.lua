-- Pure Lua reference for the DS geometry-engine vertex-lighting calculation.
-- Mirrors the formula the vertex shader will run with floats: ambient, diffuse,
-- and specular contributions are summed per enabled light, emission is added
-- once, and the result is saturated at 31 per channel and packed as RGB555.
--
-- The light vectors stored in HGSS profiles point in the direction the light
-- travels (from light source toward the surface). The diffuse factor is
-- max(0, -dot(L, N)). Specular uses the half-vector between the direction to
-- the light (-L) and the view direction V = (0, 0, 1) in camera/vector space.
-- When no shininess table is supplied the raw half-vector dot is used (exact
-- table lookup is deferred). Pure domain module: no love, arithmetic only.

local DsLighting = {}

local FX12_SCALE = 4096
local VIEW_DIRECTION = { 0, 0, 1 }

local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

function DsLighting.unpackRgb555(packed)
  return packed % 32, math.floor(packed / 32) % 32, math.floor(packed / 1024) % 32
end

local function unpackColor(packed)
  local r, g, b = DsLighting.unpackRgb555(packed)
  return { r, g, b }
end

local function dot3(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function scale3(v, s) return { v[1] * s, v[2] * s, v[3] * s } end

local function length3(v)
  return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
end

local function normalize3(v)
  local len = length3(v)
  if len < 1e-12 then return { 0, 0, 0 } end
  return { v[1] / len, v[2] / len, v[3] / len }
end

local function addInPlace(dst, src)
  dst[1] = dst[1] + src[1]
  dst[2] = dst[2] + src[2]
  dst[3] = dst[3] + src[3]
end

local function mulColor(color, factor)
  return { color[1] * factor, color[2] * factor, color[3] * factor }
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
        light.vectorFx12[1] / FX12_SCALE,
        light.vectorFx12[2] / FX12_SCALE,
        light.vectorFx12[3] / FX12_SCALE,
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

      local contrib = { ambient[1], ambient[2], ambient[3] }
      addInPlace(contrib, mulColor(diffuse, ld))
      addInPlace(contrib, mulColor(specular, ls))

      local lcolor = unpackColor(light.colorRgb555)
      addInPlace(acc, { lcolor[1] * contrib[1], lcolor[2] * contrib[2], lcolor[3] * contrib[3] })
    end
  end

  local r = math.min(31, math.floor(acc[1] + 0.5))
  local g = math.min(31, math.floor(acc[2] + 0.5))
  local b = math.min(31, math.floor(acc[3] + 0.5))
  return rgb555(r, g, b)
end

-- DS 5-bit alpha composition. `At5` is the rounded texture alpha (0..31),
-- `Ap5` the polygon alpha (0..31). `polygonMode` is "modulation" or "decal".
function DsLighting.composeAlpha5(At5, Ap5, polygonMode)
  if polygonMode == "decal" then return Ap5 end
  return math.floor((((At5 + 1) * (Ap5 + 1)) - 1) / 32)
end

return DsLighting
