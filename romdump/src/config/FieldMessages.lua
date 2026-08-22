-- Selected-set manifest for the field message and font derived classes
-- . The bank list is project-owned policy: required
-- startup compiles only what the target demo needs, never the full
-- NARC_msgdata_msg archive. Association of a map to a bank comes from the
-- frozen map catalog (romdump/src/reference/hgss/maps.lua), never from this table.

return {
  schema = 1,
  provenance = {
    repo = "pret/pokeheartgold",
    commit = "1a7f2c301c954df2d19d7f9211529f6decc8dede",
    sources = {
      { path = "include/msgdata.h" },
      { path = "src/msgdata.c" },
      { path = "src/font.c" },
      { path = "src/font_data.c" },
      { path = "src/text.c" },
      { path = "src/data/map_headers.h" },
      { path = "files/msgdata/msg/msg_0542_T20.gmm" },
      { path = "files/msgdata/msg/msg_0543_T20R0101.gmm" },
    },
  },
  -- Message banks selected for the demo scenario : the
  -- Oak's opening bank (219), two town banks plus every New Bark interior bank (544-549), because the
  -- bound scripts of the New Bark slice reference their maps' own banks, and
  -- bank 191 because the vanilla 749-752 menus (common.pokemart and the
  -- New Bark slice's menus) resolve their items there.
  banks = { 219, 542, 543, 544, 545, 546, 547, 548, 549, 191 },
  -- Font 0 is the field dialogue font (src/font.c sFontArcParam[0]).
  fontId = 0,
  fontGlyphMember = 0,
  -- Member 6 is the screen-focus indicator set the text printer blits next
  -- to YESNO prompts (GfGfxLoader_GetCharData in src/font.c).
  fontFocusIndicatorMember = 6,
  fontPaletteMember = 7,
  -- Atlas packing: 16px glyphs in a fixed grid.
  atlasGlyphsPerRow = 64,
}
