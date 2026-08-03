-- Decompilation-derived NARC catalog: maps each NARC symbol to its NarcId enum
-- value and physical NitroFS path. This is the curated subset needed by the
-- vertical slice; tools/sync_narc_catalog.lua will later regenerate the full
-- enum from a decomp checkout (spec §11.3). Pure data, no runtime dependencies.
--
-- narcId is the index into HGSS's NarcId enum / sNarcFileList; it is NOT a FAT
-- fileId. `path` is resolved to a fileId through the parsed FNT at import time.

return {
  schema = 1,
  source = {
    repo = "pret/pokeheartgold",
    commit = "1a7f2c301c954df2d19d7f9211529f6decc8dede",
    files = { "include/filesystem_files_def.h" },
    note = "Hand-curated subset. Regenerate wholesale with tools/sync_narc_catalog.lua.",
  },
  entries = {
    NARC_poketool_personal_personal = { narcId = 2, path = "a/0/0/2" },
    NARC_poketool_personal_growtbl = { narcId = 3, path = "a/0/0/3" },
    NARC_poketool_pokegra_pokegra = { narcId = 4, path = "a/0/0/4" },
    NARC_poketool_waza_waza_tbl = { narcId = 11, path = "a/0/1/1" },
    NARC_fielddata_script_scr_seq = { narcId = 12, path = "a/0/1/2" },
    NARC_graphic_font = { narcId = 16, path = "a/0/1/6" },
    NARC_itemtool_itemdata_item_data = { narcId = 17, path = "a/0/1/7" },
    NARC_itemtool_itemdata_item_icon = { narcId = 18, path = "a/0/1/8" },
    NARC_poketool_icongra_poke_icon = { narcId = 20, path = "a/0/2/0" },
    NARC_msgdata_msg = { narcId = 27, path = "a/0/2/7" },
    NARC_fielddata_eventdata_zone_event = { narcId = 32, path = "a/0/3/2" },
    NARC_poketool_personal_wotbl = { narcId = 33, path = "a/0/3/3" },
    NARC_poketool_personal_evo = { narcId = 34, path = "a/0/3/4" },
    NARC_fielddata_encountdata_g_enc_data = { narcId = 37, path = "a/0/3/7" },
    NARC_fielddata_mapmatrix_map_matrix = { narcId = 41, path = "a/0/4/1" },
    NARC_poketool_trainer_trdata = { narcId = 55, path = "a/0/5/5" },
    NARC_poketool_trainer_trpoke = { narcId = 56, path = "a/0/5/6" },
    NARC_fielddata_landdata_land_data = { narcId = 65, path = "a/0/6/5" },
    NARC_fielddata_encountdata_s_enc_data = { narcId = 136, path = "a/1/3/6" },
    NARC_fielddata_tsurepoke_tp_param = { narcId = 141, path = "a/1/4/1" },
  },
}
