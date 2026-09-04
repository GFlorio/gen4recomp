-- Source-derived weather catalog conformance: 14 presets from HgssFieldFog
-- and ordered rules with exact Lake/flag/date identities.

local Assert = require("tests.support.Assert")

local function requireCatalogCompiler()
  local ok, mod = pcall(require, "romdump.src.digest.FieldWeatherCompiler")
  if not ok then
    error(
      "FieldWeatherCompiler is absent: generated weather catalog cannot be built from HgssFieldFog and source IDs",
      0
    )
  end
  return mod
end

local T = {}

function T.catalog_contains_all_fourteen_fog_presets_through_the_fog_authority()
  local Compiler = requireCatalogCompiler()
  local HgssFieldFog = require("romdump.src.digest.HgssFieldFog")
  local bundle = assert(Compiler.compile())
  Assert.equal(bundle.catalog.schema, "g4-field-weather-v1")
  Assert.equal(
    bundle.marker,
    "field-weather-cache-v1:" .. tostring(bundle.romSha1 or "rom-sha") .. ":" .. tostring(bundle.depHash or "dep-hash")
  )
  for id = 0, 13 do
    local preset = bundle.catalog.presets[id]
    Assert.notNil(preset, "preset " .. id .. " present")
    Assert.equal(type(preset.enabled), "boolean")
    Assert.equal(type(preset.color), "number")
    Assert.equal(type(preset.offset), "number")
    Assert.equal(type(preset.slope), "number")
    Assert.equal(type(preset.alpha), "number")
    Assert.equal(#preset.table, 32, "preset " .. id .. " table has exactly 32 entries")
    local expected = HgssFieldFog.runtimePreset(HgssFieldFog.resolve(id))
    Assert.equal(preset.enabled, expected.enabled, "preset " .. id .. " enabled matches HgssFieldFog")
    Assert.equal(preset.color, expected.color, "preset " .. id .. " color matches HgssFieldFog")
    Assert.equal(preset.offset, expected.offset, "preset " .. id .. " offset matches HgssFieldFog")
    Assert.equal(preset.slope, expected.slope, "preset " .. id .. " slope matches HgssFieldFog")
    Assert.equal(preset.alpha, expected.alpha, "preset " .. id .. " alpha matches HgssFieldFog")
    Assert.deepEqual(preset.table, expected.table, "preset " .. id .. " table matches HgssFieldFog")
  end
  local count = 0
  for _ in pairs(bundle.catalog.presets) do
    count = count + 1
  end
  Assert.equal(count, 14)
end

function T.rules_are_four_with_correct_kinds_and_order()
  local Compiler = requireCatalogCompiler()
  local bundle = assert(Compiler.compile())
  local rules = bundle.catalog.rules
  Assert.equal(#rules, 4)
  Assert.equal(rules[1].kind, "calendar_map_override")
  Assert.equal(rules[2].kind, "map_var_equals")
  Assert.equal(rules[3].kind, "weather_flag_override")
  Assert.equal(rules[4].kind, "weather_flag_override")
end

function T.calendar_rule_carries_mt_silver_summit_and_exact_eight_diamond_dust_dates()
  local Compiler = requireCatalogCompiler()
  local bundle = assert(Compiler.compile())
  local rule = bundle.catalog.rules[1]
  Assert.equal(rule.mapId, 465, "Mt Silver Summit is map 465")
  Assert.equal(rule.weatherId, 8)
  Assert.isTrue(rule.requireNoPenalty == true)
  Assert.equal(#rule.dates, 8)
  local expected = {
    { month = 1, day = 1 },
    { month = 1, day = 31 },
    { month = 2, day = 1 },
    { month = 2, day = 29 },
    { month = 3, day = 15 },
    { month = 10, day = 10 },
    { month = 12, day = 3 },
    { month = 12, day = 31 },
  }
  for i = 1, 8 do
    Assert.equal(rule.dates[i].month, expected[i].month, "date " .. i .. " month")
    Assert.equal(rule.dates[i].day, expected[i].day, "date " .. i .. " day")
  end
end

function T.lake_rule_carries_exact_var_id_and_value()
  local Compiler = requireCatalogCompiler()
  local bundle = assert(Compiler.compile())
  local rule = bundle.catalog.rules[2]
  Assert.equal(rule.mapId, 88, "Lake of Rage is map 88")
  Assert.equal(rule.varId, 0x4037)
  Assert.equal(rule.value, 0xF229)
  Assert.equal(rule.weatherId, 0)
end

function T.defog_rule_rewrites_9_to_0_with_resolved_flag_id()
  local Compiler = requireCatalogCompiler()
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local bundle = assert(Compiler.compile())
  local rule = bundle.catalog.rules[3]
  Assert.equal(rule.fromWeatherId, 9)
  Assert.equal(rule.flagId, FieldScriptSymbols.flagsByName.FLAG_SYS_DEFOG)
  Assert.equal(rule.flagId, 2420)
  Assert.equal(rule.weatherId, 0)
end

function T.flash_rule_rewrites_11_to_12_with_resolved_flag_id()
  local Compiler = requireCatalogCompiler()
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local bundle = assert(Compiler.compile())
  local rule = bundle.catalog.rules[4]
  Assert.equal(rule.fromWeatherId, 11)
  Assert.equal(rule.flagId, FieldScriptSymbols.flagsByName.FLAG_SYS_FLASH)
  Assert.equal(rule.flagId, 2419)
  Assert.equal(rule.weatherId, 12)
end

function T.every_rule_target_weather_exists_in_presets()
  local Compiler = requireCatalogCompiler()
  local bundle = assert(Compiler.compile())
  for i, rule in ipairs(bundle.catalog.rules) do
    Assert.notNil(bundle.catalog.presets[rule.weatherId], "rule " .. i .. " target " .. rule.weatherId .. " present")
  end
end

return { tests = T, metadata = { capabilities = {} } }
