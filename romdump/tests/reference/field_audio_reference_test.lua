-- Frozen producer facts for HGSS field audio: the thirteen flag-driven
-- map-music override rules, the surfing traversal override, the sixteen-entry
-- soundplate semantic table, and the BGM duck targets. These are source
-- literals (data, not algorithms) pinned so the field-audio contract in the
-- reference module cannot drift; each record also cross-resolves against the
-- already-frozen map, sequence, and flag catalogs.

local Assert = require("tests.support.Assert")
local fieldAudio = require("romdump.src.reference.hgss.field_audio")

local maps = require("romdump.src.reference.hgss.maps")
local sndseq = require("romdump.src.reference.hgss.sndseq")
local flags = require("romdump.src.reference.hgss.flags")

local T = {}

local seqByName = {}
for _, name in pairs(sndseq.byId) do
  seqByName[name] = true
end

local mapSymbols = {}
for id = 0, maps.count - 1 do
  mapSymbols[maps.byId[id].symbol] = true
end

-- The thirteen src/sys_flags.c rules in source order.
local EXPECTED_FLAG_MUSIC = {
  { map = "MAP_NATIONAL_PARK", flagId = 0x993, sequence = "SEQ_GS_TAIKAIMAE_D5" },
  { map = "MAP_ROUTE_35_NATIONAL_PARK_POKEATHALON_GATEHOUSE", flagId = 0x993, sequence = "SEQ_GS_TAIKAIMAE" },
  { map = "MAP_ROUTE_36_NATIONAL_PARK_GATEHOUSE", flagId = 0x993, sequence = "SEQ_GS_TAIKAIMAE" },
  { map = "MAP_CERULEAN_GYM", flagId = 0x994, sequence = "SEQ_GS_EYE_ROCKET" },
  { map = "MAP_ROUTE_24", flagId = 0x995, sequence = "SEQ_GS_EYE_ROCKET" },
  { map = "MAP_PAL_PARK", flagId = 0x999, sequence = "SEQ_GS_SAFARI_FIELD" },
  { map = "MAP_GOLDENROD_RADIO_TOWER_1F", flagId = 0x99B, sequence = "SEQ_GS_SENKYO" },
  { map = "MAP_GOLDENROD_RADIO_TOWER_2F", flagId = 0x99B, sequence = "SEQ_GS_SENKYO" },
  { map = "MAP_GOLDENROD_RADIO_TOWER_3F", flagId = 0x99B, sequence = "SEQ_GS_SENKYO" },
  { map = "MAP_GOLDENROD_RADIO_TOWER_4F", flagId = 0x99B, sequence = "SEQ_GS_SENKYO" },
  { map = "MAP_GOLDENROD_RADIO_TOWER_5F", flagId = 0x99B, sequence = "SEQ_GS_SENKYO" },
  { map = "MAP_GOLDENROD_RADIO_TOWER_OBSERVATION_DECK", flagId = 0x99B, sequence = "SEQ_GS_SENKYO" },
  { map = "MAP_GOLDENROD_RADIO_TOWER_ELEVATOR", flagId = 0x99B, sequence = "SEQ_GS_SENKYO" },
}

-- The source surfing override; ambient levels are the far/mid/close ramp
-- selected by volumeIndex (levels[volumeIndex + 1]). The four disable rules of
-- FieldSystem_SoundplateIsActive (field_control.c) ride on their sound entries
-- as `disableWhen = {flagId, map?}`: a map-scoped rule applies only on its
-- named gym map, an unscoped rule on every map carrying that sound.
local EXPECTED_SOUNDPLATES = {
  { kind = "water_flow", sequence = "SEQ_SE_GS_N_SESERAGI", useFieldMusicBank = true, ambientLevels = { 64, 96, 127 } },
  { kind = "windmill", sequence = "SEQ_SE_GS_N_HUUSHA", useFieldMusicBank = false, ambientLevels = { 46, 96, 127 } },
  { kind = "seashore", sequence = "SEQ_SE_GS_N_UMIBE", useFieldMusicBank = false, ambientLevels = { 46, 96, 127 } },
  { kind = "pillar", sequence = "SEQ_SE_GS_N_HASHIRA", useFieldMusicBank = true, ambientLevels = { 64, 96, 127 } },
  { kind = "whirlpool", sequence = "SEQ_SE_GS_N_UZUSIO", useFieldMusicBank = false, ambientLevels = { 46, 64, 96 } },
  {
    kind = "waterfall",
    sequence = "SEQ_SE_GS_N_TAKI",
    useFieldMusicBank = false,
    ambientLevels = { 64, 96, 108 },
    disableWhen = { flagId = 0x981, map = "MAP_CIANWOOD_GYM" },
  },
  { kind = "lava", sequence = "SEQ_SE_GS_N_YOUGAN", useFieldMusicBank = true, ambientLevels = { 46, 96, 108 } },
  { kind = "cheers", sequence = "SEQ_SE_GS_N_KANSEI", useFieldMusicBank = false, ambientLevels = { 46, 96, 127 } },
  {
    kind = "steam_whistle",
    sequence = "SEQ_SE_GS_N_KITEKI",
    useFieldMusicBank = false,
    ambientLevels = { 46, 96, 127 },
  },
  {
    kind = "snorlax_snoring",
    sequence = "SEQ_SE_GS_KABIGON_IBIKI",
    useFieldMusicBank = true,
    ambientLevels = { 46, 96, 127 },
    disableWhen = { flagId = 0xF9 },
  },
  {
    kind = "motor",
    sequence = "SEQ_SE_GS_N_MOTER",
    useFieldMusicBank = true,
    ambientLevels = { 46, 96, 127 },
    disableWhen = { flagId = 0xCA },
  },
  { kind = "bells", sequence = "SEQ_SE_GS_N_KANE", useFieldMusicBank = true, ambientLevels = { 46, 72, 108 } },
  { kind = "strong_wind", sequence = "SEQ_SE_GS_KYOUHUU", useFieldMusicBank = true, ambientLevels = { 46, 96, 127 } },
  { kind = "engine", sequence = "SEQ_SE_GS_N_ENGINE", useFieldMusicBank = true, ambientLevels = { 46, 96, 127 } },
  { kind = "fountain", sequence = "SEQ_SE_GS_N_HUNSUI", useFieldMusicBank = false, ambientLevels = { 64, 96, 127 } },
  {
    kind = "electric_barrier",
    sequence = "SEQ_SE_GS_DENGEKIBARIA",
    useFieldMusicBank = false,
    ambientLevels = { 46, 96, 127 },
    disableWhen = { flagId = 0x9A6, map = "MAP_VERMILION_GYM" },
  },
}

function T.flag_music_overrides_pin_the_thirteen_sys_flags_rules()
  Assert.deepEqual(fieldAudio.flagMusicOverrides, EXPECTED_FLAG_MUSIC)
  local seen = {}
  for _, rule in ipairs(fieldAudio.flagMusicOverrides) do
    Assert.isTrue(mapSymbols[rule.map], "unknown map symbol " .. rule.map)
    Assert.notNil(flags.byId[rule.flagId], "unknown flag id 0x" .. string.format("%X", rule.flagId))
    Assert.isTrue(seqByName[rule.sequence], "unknown sequence symbol " .. rule.sequence)
    Assert.isNil(seen[rule.map], "duplicate map rule " .. rule.map)
    seen[rule.map] = true
  end
end

function T.traversal_override_pins_the_surfing_rule()
  Assert.equal(#fieldAudio.traversalOverrides, 1)
  local rule = fieldAudio.traversalOverrides[1]
  Assert.deepEqual(rule, { traversal = "surfing", sequence = "SEQ_GS_NAMINORI", unlessFlagId = 0x99A })
  Assert.isTrue(seqByName[rule.sequence], "unknown sequence symbol " .. rule.sequence)
  Assert.notNil(flags.byId[rule.unlessFlagId], "unknown flag id 0x" .. string.format("%X", rule.unlessFlagId))
end

function T.soundplate_table_pins_all_sixteen_records()
  Assert.deepEqual(fieldAudio.soundplates, EXPECTED_SOUNDPLATES)
  local seen = {}
  for _, record in ipairs(fieldAudio.soundplates) do
    Assert.isTrue(seqByName[record.sequence], "unknown sequence symbol " .. record.sequence)
    Assert.isNil(seen[record.kind], "duplicate soundplate kind " .. record.kind)
    seen[record.kind] = true
  end
end

-- The disable metadata lives only on the four source-gated sounds, carries the
-- exact flag ids, and every named map scope resolves in the frozen map catalog
-- (an impossible map name would silently drop the rule otherwise).
function T.disable_rules_ride_the_frozen_sound_entries()
  local rules = {}
  for index, record in ipairs(fieldAudio.soundplates) do
    local rule = record.disableWhen
    if rule ~= nil then
      Assert.notNil(flags.byId[rule.flagId], "unknown flag id 0x" .. string.format("%X", rule.flagId))
      if rule.map ~= nil then
        Assert.isTrue(mapSymbols[rule.map], "unknown map symbol " .. rule.map)
      end
      rules[index - 1] = { flagId = rule.flagId, map = rule.map }
    end
  end
  Assert.deepEqual(rules, {
    [5] = { flagId = 0x981, map = "MAP_CIANWOOD_GYM" },
    [9] = { flagId = 0xF9, map = nil },
    [10] = { flagId = 0xCA, map = nil },
    [15] = { flagId = 0x9A6, map = "MAP_VERMILION_GYM" },
  })
end

function T.bgm_duck_targets_pin_the_volume_indices()
  Assert.deepEqual(fieldAudio.bgmDuckTargets, { 96, 64, 32 })
end

-- A disableWhen rule must always name the flag that gates the sound; a rule
-- without a flagId would silently emit nothing and read as "never disabled".
function T.disable_rules_always_carry_a_flag()
  for index, record in ipairs(fieldAudio.soundplates) do
    if record.disableWhen ~= nil then
      Assert.notNil(
        record.disableWhen.flagId,
        "soundplate " .. (index - 1) .. " (" .. record.kind .. ") disableWhen lacks a flagId"
      )
    end
  end
end

return { tests = T }
