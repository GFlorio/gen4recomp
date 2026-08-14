-- Tests for the DS vertex-lighting reference: disabled lights, ambient,
-- diffuse front/back-facing, emission alone, multiple lights, saturation,
-- material-owned versus field-owned colors, the front-light specular gate,
-- and the fixed-point truncation pipeline itself (fractional diffuse levels,
-- the cos(2a) specular square). Alpha composition (MODULATE/DECAL) lives in
-- DsFragment and is tested there, not here.

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
  }
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
  -- ld = max(0, -dot(L,N)) = full scale (512).
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
  -- 2 * floor(31*20/31) = 2*20 = 40 -> clamped at full scale.
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

function T.light_mask_changes_the_lit_result_for_the_same_profile()
  local function lit(mask)
    return DsLighting.vertexColorRgb5(params({
      diffuse = rgb555(31, 31, 31),
      lights = {
        { enabled = true, colorRgb555 = rgb555(31, 0, 0), vectorFx12 = { 0, 0, -4096 } },
        { enabled = true, colorRgb555 = rgb555(0, 0, 31), vectorFx12 = { 0, 0, -4096 } },
      },
      lightMask = mask,
    }))
  end
  Assert.equal(lit(0), rgb555(0, 0, 0))
  Assert.equal(lit(1), rgb555(31, 0, 0))
  Assert.equal(lit(2), rgb555(0, 0, 31))
  Assert.equal(lit(3), rgb555(31, 0, 31))
end

-- The integer pipeline's own truncation replaces incidental floating-point
-- rounding: lightColor*(ambient+diffuse) = 31*(2+8)/31 and 31*(2+16)/31 land
-- on exact integers here (10 and 18), unlike an ordinary float multiply that
-- can sit one ULP below the boundary. The reference must not reintroduce
-- that float rounding artifact.
function T.material_owned_channel_used_when_passed()
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(8, 16, 24),
    ambient = rgb555(2, 2, 2),
    lights = { light(31, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  local r, g, b = DsLighting.unpackRgb555(c)
  Assert.equal(r, 10)
  Assert.equal(g, 18)
  Assert.equal(b, 26)
end

function T.midrange_colors_scale_with_light_intensity()
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(20, 15, 10),
    ambient = rgb555(5, 5, 5),
    lights = { { enabled = true, colorRgb555 = rgb555(15, 20, 25), vectorFx12 = { 0, 0, -4096 } } },
    lightMask = 1,
  }))
  -- termSum = (25,20,15); floor(15*25/31), floor(20*20/31), floor(25*15/31) -> 12,12,12.
  Assert.equal(c, rgb555(12, 12, 12))
end

-- Real HGSS profile colors with a head-on light so ambient, diffuse, and the
-- profile's nonzero specular all land on clean values: termSum = (38,38,42),
-- lightContribution = floor(11*38/31), floor(11*38/31), floor(16*42/31) ->
-- 13,13,21; plus emission (8,8,11) -> (21,21,32) clamped to (21,21,31).
function T.head_on_profile_colors_quantize_like_the_shader()
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(14, 14, 16),
    ambient = rgb555(10, 10, 10),
    specular = rgb555(14, 14, 16),
    emission = rgb555(8, 8, 11),
    lights = { { enabled = true, colorRgb555 = rgb555(11, 11, 16), vectorFx12 = { 0, 0, -4096 } } },
    lightMask = 1,
  }))
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
  -- A 1/31 light with midrange material truncates to zero: floor(1*15/31)=0.
  local d = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(15, 15, 15),
    lights = { light(1, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  Assert.equal(d, rgb555(0, 0, 0))
end

-- A light 60 degrees off the normal truncates to a half-scale diffuse level
-- (dot(L,N) = -0.5 exactly for these vectors): diffuseTerm =
-- floor(20*256/512) = 10, termSum = 14, lightContribution =
-- floor(30*14/31) = 13.
function T.diffuse_at_an_angle_truncates_the_fractional_level()
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(20, 20, 20),
    ambient = rgb555(4, 4, 4),
    lights = { light(30, { 3548, 0, -2048 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(13, 13, 13))
end

-- Two lights at the same fractional angle sum as plain integers before the
-- final saturating clamp: 13 (from the case above) + floor(10*14/31) = 4.
function T.two_lights_at_fractional_levels_sum_before_the_final_clamp()
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(20, 20, 20),
    ambient = rgb555(4, 4, 4),
    lights = {
      light(30, { 3548, 0, -2048 }),
      light(10, { -3548, 0, -2048 }),
    },
    lightMask = 3,
  }))
  Assert.equal(c, rgb555(17, 17, 17))
end

-- The melonDS cos(2a) midrange pins: isolate specular with one white
-- (31,31,31) light, material specular (14,14,16), zero
-- diffuse/ambient/emission, L = (0,0,-1) and N(d) = (sqrt(1-d^2), 0, d), so
-- dot(N,H) truncates to exactly d*512 and the truncated square reproduces
-- the melonDS cos(2a) term ls = clamp(2*d^2 - 1, 0, 1):
--   d=0.25 -> ls=0     -> (0,0,0)
--   d=0.50 -> ls=0     -> (0,0,0)
--   d=0.75 -> ls=64/512 -> (1,1,2)  (floor(14*64/512)=1, floor(16*64/512)=2)
--   d=1.00 -> ls=512/512 -> (14,14,16), the unchanged head-on case
function T.cos2a_specular_pins_at_midrange()
  local function lit(d)
    return DsLighting.vertexColorRgb5(params({
      normal = { math.sqrt(1 - d * d), 0, d },
      diffuse = rgb555(0, 0, 0),
      specular = rgb555(14, 14, 16),
      lights = { light(31, { 0, 0, -4096 }) },
      lightMask = 1,
    }))
  end
  for _, d in ipairs({ 0.25, 0.5 }) do
    local r, g, b = DsLighting.unpackRgb555(lit(d))
    Assert.equal(r, 0, "d=" .. d .. " red")
    Assert.equal(g, 0, "d=" .. d .. " green")
    Assert.equal(b, 0, "d=" .. d .. " blue")
  end
  Assert.equal(lit(0.75), rgb555(1, 1, 2))
  Assert.equal(lit(1.0), rgb555(14, 14, 16))
end

-- The gate that separates melonDS from DeSmuME: a light whose travel
-- direction is behind the surface, dot(-L,N) < 0, yet whose half vector
-- still lies in front of it, dot(N,H) > 1/sqrt(2), so the cos(2a) scalar
-- would be positive. N at 30deg from +z; L travels at 60deg from +z on the
-- far side (fx12 {-3313, 0, 2407}): -L = (0.809, 0, -0.588),
-- dot(-L,N) = -0.105, H = normalize(-L+z) = (0.891, 0, 0.454),
-- dot(N,H) = 0.839. The melonDS front-light gate zeroes specular (-> ls 0 ->
-- (0,0,0) for white light over (14,14,16)); a DeSmuME h > 0 gate would
-- compute ls = 2*0.839^2 - 1 = 0.407 -> (6,6,7). The reference must not
-- contribute here.
function T.melonds_front_gate_zeroes_specular_behind_the_surface()
  local c = DsLighting.vertexColorRgb5(params({
    normal = { 0.5, 0, 0.8660254037844386 },
    diffuse = rgb555(0, 0, 0),
    specular = rgb555(14, 14, 16),
    lights = { light(31, { -3313, 0, 2407 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(0, 0, 0))
end

return { tests = T }
