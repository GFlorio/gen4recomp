-- Frozen producer facts for HGSS field audio, normalized from
-- pret/pokeheartgold. Flag-driven map-music overrides come from
-- src/sys_flags.c, the surfing traversal override from FieldBGM_GetEffective in
-- src/field_bgm.c, and the soundplate sequence/field-music-bank table,
-- ambient volume table, BGM duck targets, and per-sound disable rules from
-- src/field/field_control.c (FieldSystem_SoundplateIsActive).
-- Producer-only reference data: the runtime must never require this module.

return {
  -- The thirteen src/sys_flags.c map-music override rules, in source order.
  flagMusicOverrides = {
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
  },
  -- The source effective-music surfing override: before map-header music
  -- unless the suppressing flag is set. Has higher precedence than a persisted
  -- field-music override.
  traversalOverrides = {
    { traversal = "surfing", sequence = "SEQ_GS_NAMINORI", unlessFlagId = 0x99A },
  },
  -- The sixteen src/field/field_control.c soundplate sound types. ambientLevels
  -- is the far/mid/close volume triple indexed by the plate's volumeIndex
  -- (levels[volumeIndex + 1]); useFieldMusicBank=true plates borrow the field
  -- BGM bank instead of their own. A plate carrying disableWhen = { flagId,
  -- map? } is gated by that event-state flag: a map-scoped rule applies only
  -- on its named map, an unscoped rule on every map carrying the sound.
  soundplates = {
    {
      kind = "water_flow",
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = true,
      ambientLevels = { 64, 96, 127 },
    },
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
  },
  -- Source field-BGM duck targets per plate volumeIndex (bgmTarget = bgmDuckTargets[volumeIndex + 1]).
  bgmDuckTargets = { 96, 64, 32 },
}
