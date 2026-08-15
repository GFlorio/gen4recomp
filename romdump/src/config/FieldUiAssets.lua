-- Source-only member selection for the generated HGSS field-UI class. Every
-- NARC alias/member number lives here and in the dependencies/provenance
-- records; the generated manifest never carries them. Member numbers are
-- zero-based per the repository convention. The wayfinding selection is the
-- corpus-audited set: the real scr_seq material uses types {0,1,2,3,4,5,8,9,
-- 10,11,13,15,16,17,18,19,20,21,23,28,29,30,33,34,39} with type/map operands
-- (0,0), (0,1), (1,0), (1,1); per LoadMapSignpostFrameAndGraphic
-- (asm/render_window.s at the pinned decomp commit) the wayfinding member
-- is map + 0x21 for type 0 and map + 2 for type 1. Start Menu members follow
-- src/start_menu.c, dialogue frames LoadUserFrameGfx2 (member = frame + 2,
-- palette = frame + 0x1A), Trainer Card members src/overlay_trainer_card_main.s.
-- No sound archive is selected: the branch does not reproduce the source
-- Start Menu effects.

return {
  schema = 1,
  provenance = {
    repo = "pret/pokeheartgold",
    commit = "7e25c842061d026f43fe6efbd7be0ec94c50839d",
    sources = {
      { path = "src/start_menu.c" },
      { path = "asm/render_window.s" },
      { path = "src/overlay_trainer_card_main.s" },
    },
  },
  startMenu = {
    alias = "start_menu",
    backgroundCharMember = 12,
    backgroundScreenMember = 13,
    backgroundPaletteMember = 15,
    cursorCharMember = 64,
    cursorPaletteMember = 61,
    cursorCellMember = 62,
    cursorAnimMember = 63,
  },
  dialogueFrames = {
    alias = "dialogue_frames",
    firstFrameMember = 2,
    frameCount = 20,
    firstPaletteMember = 26,
    tilesPerFrame = 20,
  },
  signposts = {
    alias = "signpost_graphics",
    frameMember = 0,
    paletteMember = 1,
    -- (type, map) -> wayfinding member (map + 0x21 for type 0, map + 2 for
    -- type 1), audited from the real scr_seq corpus.
    wayfinding = {
      ["0.0"] = 0x21,
      ["0.1"] = 0x22,
      ["1.0"] = 2,
      ["1.1"] = 3,
    },
    -- Every signpost source type found in the corpus, kept as raw numbers
    -- (the style catalogue owns their semantics).
    sourceTypes = { 0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 13, 15, 16, 17, 18, 19, 20, 21, 23, 28, 29, 30, 33, 34, 39 },
  },
  trainerCard = {
    alias = "trainer_card_graphics",
    frontCharMember = 41,
    frontScreenMember = 47,
    frontPaletteMember = 11,
  },
}
