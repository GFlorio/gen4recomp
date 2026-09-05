-- Tests for HgssFieldFog, the steady-state HGSS weather-fog preset table,
-- recovered from pokeheartgold overlay 01's weather dispatch table and its
-- handler literal pools, cross-checked against GBATEK's "3D Display - Fog"
-- FOG_OFFSET/FOG_TABLE bit layout and GX_g3x.h's GXFogSlope enum, pinned to
-- pokeheartgold commit 7e25c842061d026f43fe6efbd7be0ec94c50839d. Scope is
-- steady-state presets only -- no calendar-date, save-flag, Defog, or
-- Flash-move override.

local Assert = require("tests.support.Assert")
local HgssFieldFog = require("romdump.src.digest.field.HgssFieldFog")

local T = {}

local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

local BLACK = rgb555(0, 0, 0)
local WHITE = rgb555(31, 31, 31)
local GREY_26 = rgb555(26, 26, 26)
local GREY_24 = rgb555(24, 24, 24)
local COLOR_1 = rgb555(1, 1, 1)

-- The common generated density ramp: 32 entries, 0, 4, 8, ..., 124.
function T.ramp_table_is_the_generated_zero_to_124_step_4_sequence()
  local ramp = HgssFieldFog.rampTable()
  Assert.equal(#ramp, 32)
  for i = 1, 32 do
    Assert.equal(ramp[i], (i - 1) * 4, "ramp entry " .. i)
  end
end

-- Flash/Flash-2 fill a temporary buffer with 0xFF and send it directly,
-- rather than using the generated ramp.
function T.flash_table_is_all_255()
  local flash = HgssFieldFog.flashTable()
  Assert.equal(#flash, 32)
  for i = 1, 32 do
    Assert.equal(flash[i], 255, "flash entry " .. i)
  end
end

-- Weather 0 (Sunny) and 7 (Sandstorm) never establish their own fog preset;
-- Fog_New's zero/disabled state is the semantically relevant preset.
function T.sunny_and_sandstorm_are_disabled()
  for _, weatherId in ipairs({ 0, 7 }) do
    local preset = HgssFieldFog.resolve(weatherId)
    Assert.isFalse(preset.enabled, "weather " .. weatherId .. " is disabled")
  end
end

-- Rain / Heavy Rain / Thunderstorm (1-3): offset 0x726F, color (26,26,26),
-- slope 3 (0x1000), alpha 31, the common ramp table.
function T.rain_family_matches_the_ov01_021ec94c_literals()
  for _, weatherId in ipairs({ 1, 2, 3 }) do
    local preset = HgssFieldFog.resolve(weatherId)
    Assert.isTrue(preset.enabled, "weather " .. weatherId .. " is enabled")
    Assert.equal(preset.offset, 0x726F, "weather " .. weatherId .. " offset")
    Assert.equal(preset.color, GREY_26, "weather " .. weatherId .. " color")
    Assert.equal(preset.slope, 3, "weather " .. weatherId .. " slope")
    Assert.equal(preset.alpha, 31, "weather " .. weatherId .. " alpha")
    Assert.deepEqual(preset.table, HgssFieldFog.rampTable(), "weather " .. weatherId .. " table")
  end
end

-- Unknown-4 / Snow / Blizzard (4-6): same offset and slope as the rain
-- family, but a distinct color (24,24,24) -- ov01_021ECD08's own literal
-- pool, not a copy of the rain handler's.
function T.unknown4_snow_blizzard_share_offset_and_slope_but_not_color()
  for _, weatherId in ipairs({ 4, 5, 6 }) do
    local preset = HgssFieldFog.resolve(weatherId)
    Assert.isTrue(preset.enabled)
    Assert.equal(preset.offset, 0x726F, "weather " .. weatherId .. " offset")
    Assert.equal(preset.color, GREY_24, "weather " .. weatherId .. " color")
    Assert.equal(preset.slope, 3, "weather " .. weatherId .. " slope")
  end
end

-- Diamond Dust (8): ov01_021ED0F0's own offset, the rain family's color.
function T.diamond_dust_matches_ov01_021ed0f0()
  local preset = HgssFieldFog.resolve(8)
  Assert.isTrue(preset.enabled)
  Assert.equal(preset.offset, 0x716F)
  Assert.equal(preset.color, GREY_26)
  Assert.equal(preset.slope, 3)
end

-- Unknown / mist-like (9-10): ov01_021ED584's offset, white color, slope 6.
function T.mist_like_matches_ov01_021ed584()
  for _, weatherId in ipairs({ 9, 10 }) do
    local preset = HgssFieldFog.resolve(weatherId)
    Assert.isTrue(preset.enabled)
    Assert.equal(preset.offset, 0x7555, "weather " .. weatherId .. " offset")
    Assert.equal(preset.color, WHITE, "weather " .. weatherId .. " color")
    Assert.equal(preset.slope, 6, "weather " .. weatherId .. " slope")
  end
end

-- Flash / Flash-2 (11-12): black, zero offset, zero alpha, slope 10, and the
-- FF-filled table instead of the ramp.
function T.flash_and_flash2_use_black_zero_offset_and_the_ff_table()
  for _, weatherId in ipairs({ 11, 12 }) do
    local preset = HgssFieldFog.resolve(weatherId)
    Assert.isTrue(preset.enabled, "weather " .. weatherId .. " is enabled")
    Assert.equal(preset.offset, 0, "weather " .. weatherId .. " offset")
    Assert.equal(preset.color, BLACK, "weather " .. weatherId .. " color")
    Assert.equal(preset.slope, 10, "weather " .. weatherId .. " slope")
    Assert.equal(preset.alpha, 0, "weather " .. weatherId .. " alpha")
    Assert.deepEqual(preset.table, HgssFieldFog.flashTable(), "weather " .. weatherId .. " table")
  end
end

-- Low Light (13): ov01_021EDA50's traced color/offset, slope 1.
function T.low_light_matches_ov01_021eda50()
  local preset = HgssFieldFog.resolve(13)
  Assert.isTrue(preset.enabled)
  Assert.equal(preset.offset, 0x4B6F)
  Assert.equal(preset.color, COLOR_1)
  Assert.equal(preset.slope, 1)
end

-- The manager explicitly bounds weather IDs below 14; anything outside
-- 0..13 is a corrupted producer input, not a value to clamp or default.
function T.resolve_rejects_weather_ids_outside_0_to_13()
  Assert.throws(function()
    HgssFieldFog.resolve(14)
  end)
  Assert.throws(function()
    HgssFieldFog.resolve(-1)
  end)
  Assert.throws(function()
    HgssFieldFog.resolve(1.5)
  end)
end

-- The runtime-relevant subset attached to a compiled map scene: enabled,
-- slope, offset, color, alpha, and the resolved 32-entry table. blendMode is
-- never carried -- every steady-state preset uses GX_FOGBLEND_COLOR_ALPHA
-- (blendMode 0), so runtimePreset asserts that invariant instead of
-- serializing a field with exactly one observed value (see the
-- non-zero-blend-mode rejection test below).
function T.runtime_preset_carries_slope_offset_color_alpha_and_table_but_not_blend_mode()
  local full = HgssFieldFog.resolve(1)
  local runtime = HgssFieldFog.runtimePreset(full)
  Assert.equal(runtime.enabled, full.enabled)
  Assert.equal(runtime.slope, full.slope)
  Assert.equal(runtime.offset, full.offset)
  Assert.equal(runtime.color, full.color)
  Assert.equal(runtime.alpha, full.alpha)
  Assert.deepEqual(runtime.table, full.table)
  Assert.isNil(runtime.blendMode, "runtime preset omits blend mode")
end

function T.runtime_preset_for_a_disabled_weather_is_harmlessly_zeroed()
  local full = HgssFieldFog.resolve(0)
  local runtime = HgssFieldFog.runtimePreset(full)
  Assert.isFalse(runtime.enabled)
  Assert.equal(runtime.slope, 0)
  Assert.equal(runtime.offset, 0)
  Assert.equal(runtime.color, BLACK)
  Assert.equal(runtime.alpha, 0)
end

-- Every currently supported HGSS steady-state preset uses blend mode 0
-- (color+alpha). runtimePreset must fail loudly rather than silently
-- dropping a hypothetical future alpha-only (blendMode 1) source preset.
function T.runtime_preset_rejects_a_source_preset_with_nonzero_blend_mode()
  local full = HgssFieldFog.resolve(1)
  local alphaOnly = {
    enabled = full.enabled,
    blendMode = 1,
    slope = full.slope,
    offset = full.offset,
    color = full.color,
    alpha = full.alpha,
    table = full.table,
  }
  local err = Assert.throws(function()
    HgssFieldFog.runtimePreset(alphaOnly)
  end)
  Assert.isTrue(
    tostring(err):find("blend", 1, true) ~= nil,
    "error should name the blend-mode invariant, got: " .. tostring(err)
  )
end

return { tests = T }
