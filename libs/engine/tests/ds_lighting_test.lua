-- Tests for the DS vertex-lighting reference: disabled lights, ambient,
-- diffuse front/back-facing, emission alone, multiple lights, saturation,
-- and material-owned versus field-owned colors.

local Assert = require("tests.support.Assert")
local DsLighting = require("libs.engine.src.DsLighting")

local T = {}

local function rgb555(r, g, b) return r + g * 32 + b * 1024 end

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

function T.emission_with_no_enabled_lights()
  local c = DsLighting.vertexColorRgb5(params({ emission = rgb555(5, 10, 15), lightMask = 0 }))
  local r, g, b = DsLighting.unpackRgb555(c)
  Assert.equal(r, 5); Assert.equal(g, 10); Assert.equal(b, 15)
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
  Assert.equal(r, 4); Assert.equal(g, 4); Assert.equal(b, 4)
end

function T.light_mask_selects_lights()
  local l1 = light(31, { 0, 0, -4096 }) -- travels -Z, lights +Z surface
  local l2 = light(31, { 0, 0, 4096 })  -- travels +Z, behind +Z surface
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
  -- 20 + 20 = 40 -> saturated at 31.
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
  Assert.equal(r, 31); Assert.equal(g, 25); Assert.equal(b, 25)
end

function T.material_owned_channel_used_when_passed()
  -- The reference itself is agnostic to ownership; callers pass the effective
  -- colors. A "material-owned" fixture uses non-field colors and a dim light
  -- so the sum is not saturated.
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(8, 16, 24),
    ambient = rgb555(2, 2, 2),
    lights = { light(1, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  local r, g, b = DsLighting.unpackRgb555(c)
  -- lightColor * (ambient + diffuse) = 1 * (10, 18, 26)
  Assert.equal(r, 10); Assert.equal(g, 18); Assert.equal(b, 26)
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
