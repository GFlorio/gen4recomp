-- HGSS's steady-state global field-fog presets, one per `WeatherManager_New`
-- weather ID (0-13), recovered from pokeheartgold overlay 01's weather
-- dispatch table and its handler literal pools. Pinned to the same
-- pokeheartgold commit `romdump/src/reference/hgss/maps.lua` already cites
-- (7e25c842061d026f43fe6efbd7be0ec94c50839d); overlay 01's weather handlers
-- have not yet been converted from `asm/overlay_01_021EB1E8.s` to C at that
-- commit, so the citations below are overlay-01 virtual addresses rather
-- than decompiled symbol names.
--
-- The 14-record dispatch table lives at `ov01_022098B0` (overlay 01 .data);
-- each record's handler resolves to one of the groups below. Handler
-- addresses and their literal-pool constants:
--
--   weather  handler          offset literal   color literal   slope
--   0        ov01_021EC8F8    (no fog: Fog_New's disabled default)
--   1-3      ov01_021EC94C    0x726F            0x6B5A          3
--   4-6      ov01_021ECD08    0x726F            0x6318          3
--   7        ov01_021EC8F8    (no fog: shares weather 0's handler)
--   8        ov01_021ED0F0    0x716F            0x6B5A          3
--   9-10     ov01_021ED584    0x7555            0x7FFF          6
--   11-12    ov01_021ED710 /  0 (zero fog color/offset, FF-filled table)
--            ov01_021ED924
--   13       ov01_021EDA50    0x4B6F            0x0421          1
--
-- For weathers 1-10 and 13, the 32-byte fog-density table is not stored in
-- the ROM at all: `ov01_021EC774`/`ov01_021EC828` procedurally generate the
-- ramp `[0, 4, 8, ..., 124]` on ordinary map load (rampTable below). Flash
-- and Flash-2 (11-12) instead fill their table with 0xFF (flashTable below)
-- and force enable=1, blend mode 0, slope 10, offset 0, color 0, alpha 0.
--
-- `ov01_021EC678` is why every enabled preset shares blend mode 0
-- (GX_FOGBLEND_COLOR_ALPHA) and fog-color alpha 31 (except Flash/Flash-2,
-- whose handler sets alpha 0 directly).
--
-- Colors are packed RGB555, matching HgssFieldEdgeColors/HgssFieldLighting's
-- existing convention: value = r + g*32 + b*1024, each channel 0-31.

local HgssFieldFog = {}

local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

local BLACK = rgb555(0, 0, 0)
local WHITE = rgb555(31, 31, 31)
local GREY_26 = rgb555(26, 26, 26)
local GREY_24 = rgb555(24, 24, 24)
local COLOR_1 = rgb555(1, 1, 1)

-- The common generated density ramp `ov01_021EC828` produces on ordinary map
-- load: 32 entries, 0, 4, 8, ..., 124.
---@return integer[]
function HgssFieldFog.rampTable()
  local t = {}
  for i = 1, 32 do
    t[i] = (i - 1) * 4
  end
  return t
end

-- Flash/Flash-2's handler fills a temporary 32-byte buffer with 0xFF and
-- sends it directly, rather than using the generated ramp.
---@return integer[]
function HgssFieldFog.flashTable()
  local t = {}
  for i = 1, 32 do
    t[i] = 255
  end
  return t
end

-- Disabled preset shared by weather 0 (Sunny) and 7 (Sandstorm): neither
-- establishes its own fog, so Fog_New's zero/disabled state is the
-- semantically relevant preset. Offset/color/table are harmlessly zeroed
-- rather than left undefined, matching a fresh field's actual register
-- state.
local function disabledPreset()
  return {
    enabled = false,
    blendMode = 0,
    slope = 0,
    offset = 0,
    color = BLACK,
    alpha = 0,
    table = HgssFieldFog.rampTable(),
  }
end

local function steadyPreset(offset, color, slope, table)
  return {
    enabled = true,
    blendMode = 0,
    slope = slope,
    offset = offset,
    color = color,
    alpha = 31,
    table = table,
  }
end

-- Flash/Flash-2 (11-12): the handler sets enable=1, mode=0, slope=10,
-- offset=0, color=0, alpha=0 directly, with the FF-filled table.
local function flashPreset()
  return {
    enabled = true,
    blendMode = 0,
    slope = 10,
    offset = 0,
    color = BLACK,
    alpha = 0,
    table = HgssFieldFog.flashTable(),
  }
end

-- Indexed 0-13 to mirror WeatherManager_New's dispatch table directly;
-- built once at module load since every preset is a pure constant.
local PRESETS = {
  [0] = disabledPreset(),
  steadyPreset(0x726F, GREY_26, 3, HgssFieldFog.rampTable()),
  steadyPreset(0x726F, GREY_26, 3, HgssFieldFog.rampTable()),
  steadyPreset(0x726F, GREY_26, 3, HgssFieldFog.rampTable()),
  steadyPreset(0x726F, GREY_24, 3, HgssFieldFog.rampTable()),
  steadyPreset(0x726F, GREY_24, 3, HgssFieldFog.rampTable()),
  steadyPreset(0x726F, GREY_24, 3, HgssFieldFog.rampTable()),
  disabledPreset(),
  steadyPreset(0x716F, GREY_26, 3, HgssFieldFog.rampTable()),
  steadyPreset(0x7555, WHITE, 6, HgssFieldFog.rampTable()),
  steadyPreset(0x7555, WHITE, 6, HgssFieldFog.rampTable()),
  flashPreset(),
  flashPreset(),
  steadyPreset(0x4B6F, COLOR_1, 1, HgssFieldFog.rampTable()),
}

-- Full preset for a weather ID: `enabled`, `blendMode` (always 0 in this
-- table), `slope`, `offset`, `color` (packed RGB555), `alpha`, and the
-- 32-entry `table`. Bounds-checked with `assert` (0-13, the same
-- `WeatherManager_New` 14-entry limit HGSS itself enforces) -- an internal
-- producer call, not an `Errors.raise` boundary.
---@param weatherId number 0-13, MapHeader's raw weather field
---@return table<string, unknown>
function HgssFieldFog.resolve(weatherId)
  assert(
    type(weatherId) == "number" and weatherId == math.floor(weatherId) and weatherId >= 0 and weatherId <= 13,
    "weatherId must be an integer in 0..13"
  )
  return PRESETS[weatherId]
end

-- The runtime-relevant subset of a resolved preset: `enabled`, `slope`,
-- `offset`, `color`, `alpha`, and `table`. `blendMode` is never carried --
-- every currently supported HGSS steady-state preset uses blend mode 0
-- (`GX_FOGBLEND_COLOR_ALPHA`, `ov01_021EC678`), so this asserts that
-- invariant instead of serializing a field with exactly one observed value.
-- Takes the full resolved preset (not a weatherId) so a synthetic preset can
-- exercise the blend-mode invariant directly; call sites that only have a
-- weatherId should resolve it first.
---@param full table<string, unknown> a preset as returned by `HgssFieldFog.resolve`
---@return table<string, unknown>
function HgssFieldFog.runtimePreset(full)
  assert(
    full.blendMode == 0,
    "HgssFieldFog.runtimePreset: source preset has a non-zero blend mode; only GX_FOGBLEND_COLOR_ALPHA (0) is implemented"
  )
  return {
    enabled = full.enabled,
    slope = full.slope,
    offset = full.offset,
    color = full.color,
    alpha = full.alpha,
    table = full.table,
  }
end

return HgssFieldFog
