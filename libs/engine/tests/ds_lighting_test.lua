-- Tests for the DS vertex-lighting reference: disabled lights, ambient,
-- diffuse front/back-facing, emission alone, multiple lights, saturation,
-- material-owned versus field-owned colors, and the shared CPU/shader
-- contract: DsLighting must produce exactly what the GLSL algebra in
-- shaders/map.glsl produces at midrange values.

local Assert = require("tests.support.Assert")
local DsLighting = require("libs.engine.src.DsLighting")

local T = {}

local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

local function light(color, vec)
  return { enabled = true, colorRgb555 = rgb555(color, color, color), vectorFx12 = vec }
end

local function params(opts)
  return {
    normal = opts.normal or { 0, 0, 1 },
    diffuseRgb555 = opts.diffuse or rgb555(31, 31, 31),
    ambientRgb555 = opts.ambient or rgb555(0, 0, 0),
    specularRgb555 = opts.specular or rgb555(0, 0, 0),
    emissionRgb555 = opts.emission or rgb555(0, 0, 0),
    lights = opts.lights or {},
    lightMask = opts.lightMask or 0,
    shininessTable = opts.shininessTable,
  }
end

-- One lighting case in the reference's input shape (packed RGB555 colors,
-- fx12 vectors), used by both the CPU reference and the shader-equivalent
-- helper below.
local function case(opts)
  return {
    normal = opts.normal or { 0, 0, 1 },
    diffuse = opts.diffuse or rgb555(31, 31, 31),
    ambient = opts.ambient or rgb555(0, 0, 0),
    specular = opts.specular or rgb555(0, 0, 0),
    emission = opts.emission or rgb555(0, 0, 0),
    lights = opts.lights or {},
    lightMask = opts.lightMask or 0,
  }
end

local function dot3(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function normalize3(v)
  local len = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
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

local function rgb5(packed)
  return {
    (packed % 32) / 31,
    (math.floor(packed / 32) % 32) / 31,
    (math.floor(packed / 1024) % 32) / 31,
  }
end

-- Build the normalized uniforms MapRenderer sends (rgb555ToFloat3 /
-- fx12ToFloat3): colors as c/31, vectors as v/4096.
local function shaderUniforms(c)
  local enabled, vectors, colors = {}, {}, {}
  for i = 1, 4 do
    local l = c.lights[i]
    enabled[i] = l and l.enabled or false
    if l then
      vectors[i] = { l.vectorFx12[1] / 4096, l.vectorFx12[2] / 4096, l.vectorFx12[3] / 4096 }
      colors[i] = rgb5(l.colorRgb555)
    else
      vectors[i] = { 0, 0, 0 }
      colors[i] = { 0, 0, 0 }
    end
  end
  return {
    lightEnabled = enabled,
    lightVector = vectors,
    lightColor = colors,
    diffuse = rgb5(c.diffuse),
    ambient = rgb5(c.ambient),
    specular = rgb5(c.specular),
    emission = rgb5(c.emission),
  }
end

-- Pure mirror of the GLSL algebra in shaders/map.glsl (computeDsLighting,
-- dsLightContribution, quantizeRgb5), written from the shader line by line:
-- normalized 0..1 colors, per-light lightColor * (ambient + diffuse*ld +
-- specular*ndh), clamp to [0,1], round-half-up 5-bit quantization. Returns
-- packed RGB555 so it can be compared directly with DsLighting.vertexColorRgb5.
local function shaderEquivalent(normal, u)
  local function dsLightContribution(L, lightColor)
    local ndl = dot3(L, normal)
    local ld = math.max(0, -ndl)
    local H = normalize3({ -L[1], -L[2], -L[3] + 1 })
    local ndh = math.max(0, dot3(normal, H))
    return {
      lightColor[1] * (u.ambient[1] + u.diffuse[1] * ld + u.specular[1] * ndh),
      lightColor[2] * (u.ambient[2] + u.diffuse[2] * ld + u.specular[2] * ndh),
      lightColor[3] * (u.ambient[3] + u.diffuse[3] * ld + u.specular[3] * ndh),
    }
  end

  local acc = { u.emission[1], u.emission[2], u.emission[3] }
  for i = 1, 4 do
    if u.lightEnabled[i] then
      addInPlace(acc, dsLightContribution(normalize3(u.lightVector[i]), u.lightColor[i]))
    end
  end

  local function quantize5(c)
    local clamped = c < 0 and 0 or (c > 1 and 1 or c)
    return math.floor(clamped * 31 + 0.5)
  end
  return rgb555(quantize5(acc[1]), quantize5(acc[2]), quantize5(acc[3]))
end

-- Real area00light.txt record 0 (New Bark daytime): light 0 (11,11,16)
-- pointing into the ground plane, light 2 (18,10,0) straight down, diffuse
-- (14,14,16), ambient (10,10,10), specular (14,14,16), emission (8,8,11).
local function realProfileCase(normal)
  return case({
    normal = normal,
    diffuse = rgb555(14, 14, 16),
    ambient = rgb555(10, 10, 10),
    specular = rgb555(14, 14, 16),
    emission = rgb555(8, 8, 11),
    lights = {
      { enabled = true, colorRgb555 = rgb555(11, 11, 16), vectorFx12 = { -1914, -3548, -296 } },
      { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
      { enabled = true, colorRgb555 = rgb555(18, 10, 0), vectorFx12 = { 0, 0, 4096 } },
      { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
    },
    lightMask = 5,
  })
end

function T.emission_with_no_enabled_lights()
  local c = DsLighting.vertexColorRgb5(params({ emission = rgb555(5, 10, 15), lightMask = 0 }))
  local r, g, b = DsLighting.unpackRgb555(c)
  Assert.equal(r, 5)
  Assert.equal(g, 10)
  Assert.equal(b, 15)
end

function T.ambient_from_one_enabled_light()
  -- Light color white, ambient white -> output white.
  local c = DsLighting.vertexColorRgb5(params({
    ambient = rgb555(31, 31, 31),
    lights = { light(31, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(31, 31, 31))
end

function T.diffuse_head_on()
  -- White light shining straight down -Z onto a surface facing +Z.
  -- L = (0,0,-1) (light travels toward +Z surface), N = (0,0,1).
  -- ld = max(0, -dot(L,N)) = 1.
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(31, 31, 31),
    lights = { light(31, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(31, 31, 31))
end

function T.diffuse_back_facing_is_zero()
  -- Same light, surface faces away.
  local c = DsLighting.vertexColorRgb5(params({
    normal = { 0, 0, -1 },
    diffuse = rgb555(31, 31, 31),
    lights = { light(31, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(0, 0, 0))
end

function T.disabled_light_is_ignored()
  local c = DsLighting.vertexColorRgb5(params({
    emission = rgb555(4, 4, 4),
    lights = { light(31, { 0, 0, -4096 }) },
    lightMask = 0,
  }))
  local r, g, b = DsLighting.unpackRgb555(c)
  Assert.equal(r, 4)
  Assert.equal(g, 4)
  Assert.equal(b, 4)
end

function T.light_mask_selects_lights()
  local l1 = light(31, { 0, 0, -4096 }) -- travels -Z, lights +Z surface
  local l2 = light(31, { 0, 0, 4096 }) -- travels +Z, behind +Z surface
  -- Only light 2 (mask bit 1) is enabled; it is behind the +Z normal so no diffuse.
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(10, 10, 10),
    lights = { l1, l2 },
    lightMask = 2,
  }))
  Assert.equal(c, rgb555(0, 0, 0))
end

function T.multiple_lights_sum()
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(20, 20, 20),
    lights = { light(31, { 0, 0, -4096 }), light(31, { 0, 0, -4096 }) },
    lightMask = 3,
  }))
  -- 2 * (20/31) = 1.29 -> clamped at full scale.
  Assert.equal(c, rgb555(31, 31, 31))
end

function T.saturates_per_channel()
  local c = DsLighting.vertexColorRgb5(params({
    emission = rgb555(25, 25, 25),
    diffuse = rgb555(31, 0, 0),
    lights = { light(31, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  local r, g, b = DsLighting.unpackRgb555(c)
  Assert.equal(r, 31)
  Assert.equal(g, 25)
  Assert.equal(b, 25)
end

function T.material_owned_channel_used_when_passed()
  -- The reference itself is agnostic to ownership; callers pass the effective
  -- colors. A full-intensity light with non-field colors keeps the sum below
  -- saturation so the material channels show through.
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(8, 16, 24),
    ambient = rgb555(2, 2, 2),
    lights = { light(31, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  local r, g, b = DsLighting.unpackRgb555(c)
  -- lightColor * (ambient + diffuse) = 1.0 * (10, 18, 26) / 31 each.
  Assert.equal(r, 10)
  Assert.equal(g, 18)
  Assert.equal(b, 26)
end

-- The CPU reference and the GLSL algebra agree at midrange values --
-- non-extreme colors, non-extreme angles, with and without
-- specular and multiple lights. These fixtures fail loudly under the old
-- RGB5-domain reference (which multiplied colors as saturating integers).
function T.cpu_and_shader_equivalent_lighting_agree_at_midrange()
  local cases = {
    realProfileCase({ 0, 0, 1 }),
    realProfileCase({ 0.3, 0.8, 0.5 }),
    realProfileCase({ 1, 0, 0 }),
    case({
      diffuse = rgb555(12, 18, 9),
      ambient = rgb555(4, 6, 5),
      specular = rgb555(10, 8, 12),
      emission = rgb555(3, 5, 7),
      lights = { { enabled = true, colorRgb555 = rgb555(9, 13, 20), vectorFx12 = { 1000, 2000, -3500 } } },
      lightMask = 1,
    }),
    case({
      diffuse = rgb555(15, 20, 10),
      ambient = rgb555(6, 6, 6),
      specular = rgb555(0, 0, 0),
      emission = rgb555(0, 0, 0),
      lights = {
        { enabled = true, colorRgb555 = rgb555(10, 14, 18), vectorFx12 = { -1000, 0, -3960 } },
        { enabled = true, colorRgb555 = rgb555(22, 6, 12), vectorFx12 = { 0, -1500, -3800 } },
      },
      lightMask = 3,
    }),
    case({
      normal = { 0.3, 0.3, 0.9 },
      diffuse = rgb555(20, 20, 20),
      ambient = rgb555(3, 3, 3),
      specular = rgb555(30, 30, 30),
      emission = rgb555(1, 1, 1),
      lights = { { enabled = true, colorRgb555 = rgb555(30, 30, 30), vectorFx12 = { -2048, -2048, -3072 } } },
      lightMask = 1,
    }),
    case({
      normal = { 0, 0, -1 },
      diffuse = rgb555(31, 31, 31),
      ambient = rgb555(10, 10, 10),
      specular = rgb555(20, 20, 20),
      emission = rgb555(5, 5, 5),
      lights = { { enabled = true, colorRgb555 = rgb555(31, 31, 31), vectorFx12 = { 0, 0, -4096 } } },
      lightMask = 1,
    }),
    case({
      diffuse = rgb555(7, 8, 9),
      ambient = rgb555(1, 1, 1),
      specular = rgb555(4, 5, 6),
      emission = rgb555(2, 3, 4),
      lights = { { enabled = true, colorRgb555 = rgb555(1, 2, 3), vectorFx12 = { 0, 0, -4096 } } },
      lightMask = 1,
    }),
  }
  for i, c in ipairs(cases) do
    local reference = DsLighting.vertexColorRgb5(params(c))
    local shader = shaderEquivalent(normalize3(c.normal), shaderUniforms(c))
    Assert.equal(reference, shader, "case " .. i)
  end
end

-- Hand-verified midrange anchor: colors multiplied as fractions of full scale,
-- never as saturating integers (light 15 * diffuse 20 used to saturate to 31).
function T.midrange_colors_scale_with_light_intensity()
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(20, 15, 10),
    ambient = rgb555(5, 5, 5),
    lights = { { enabled = true, colorRgb555 = rgb555(15, 20, 25), vectorFx12 = { 0, 0, -4096 } } },
    lightMask = 1,
  }))
  -- (15/31)*(25/31), (20/31)*(20/31), (25/31)*(15/31) -> 12, 13, 12.
  Assert.equal(c, rgb555(12, 13, 12))
end

-- Real HGSS profile colors with a head-on light so ambient, diffuse, and the
-- profile's nonzero specular all land on clean values (the real sun vector
-- grazes the floor at ld ~= 0.073, so this fixture swaps in a head-on vector):
-- 8/31 + (11/31)*(10+14+14)/31 -> 21, and 11/31 + (16/31)*(10+14+16)/31 -> 31.
function T.head_on_profile_colors_quantize_like_the_shader()
  local c = DsLighting.vertexColorRgb5(params(case({
    diffuse = rgb555(14, 14, 16),
    ambient = rgb555(10, 10, 10),
    specular = rgb555(14, 14, 16),
    emission = rgb555(8, 8, 11),
    lights = { { enabled = true, colorRgb555 = rgb555(11, 11, 16), vectorFx12 = { 0, 0, -4096 } } },
    lightMask = 1,
  })))
  Assert.equal(c, rgb555(21, 21, 31))
end

function T.dim_light_contributes_proportionally()
  -- A 15/31 light with full material stays at 15 (never saturates to 31).
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(31, 31, 31),
    lights = { light(15, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(15, 15, 15))
  -- A 1/31 light with midrange material is a fraction of a step and rounds
  -- away entirely; the old RGB5-domain reference returned 15.
  local d = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(15, 15, 15),
    lights = { light(1, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  Assert.equal(d, rgb555(0, 0, 0))
end

function T.composes_modulation_alpha_5bit()
  -- Full texture alpha * full polygon alpha stays full.
  Assert.equal(DsLighting.composeAlpha5(31, 31, "modulation"), 31)
  -- Zero texture alpha with any polygon alpha -> zero output.
  Assert.equal(DsLighting.composeAlpha5(0, 31, "modulation"), 0)
  -- Half texture alpha with full polygon alpha.
  Assert.equal(DsLighting.composeAlpha5(15, 31, "modulation"), 15)
end

function T.decal_alpha_ignores_texture_alpha()
  Assert.equal(DsLighting.composeAlpha5(0, 20, "decal"), 20)
  Assert.equal(DsLighting.composeAlpha5(31, 20, "decal"), 20)
end

return T
