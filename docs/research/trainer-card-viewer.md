# Trainer Card front viewer — source audit

Pinned decomp: `pret/pokeheartgold` commit `008257708` ("Merge pull request #501"),
checked out at `/workspace/tmp/refs/pokeheartgold`.

This note records the source facts behind the Trainer Card front viewer
(`TrainerCardRenderer` + `TrainerCardController`) so later card work (signature
editor, back-side/flip) can start from evidence instead of re-auditing.

## Card art

- `NARC_a_0_4_9` (narcId 49, "a/0/4/9"; `romdump/src/reference/hgss/narcs.lua`):
  member 41 char data, member 47 screen data, member 11 palette — selected in
  `romdump/src/config/FieldUiAssets.lua` `trainerCard` and compiled to
  `assets/generated/field/ui/trainer-card.png` by `FieldUiCompiler.compileTrainerCard`
  (screen is 32x32 tiles = 256x256; only the top 256x192 rows are opaque, the
  visible card fills the top screen).

## Front text layout

`ov51_021E6F18` in `asm/overlay_trainer_card_main.s` prints the front text.
Windows are created from the template table at `ov51_021E7F48` (`AddWindow`,
`WindowTemplate { u8 bg; u8 left; u8 top; u8 width; u8 height; u8 palette; u16
baseTile }` per `include/bg_window.h`, 8px/tile). The front windows (bg 7):

| window | rect (px)      | label (msgdata bank 727) | value print |
| ------ | -------------- | ------------------------ | ----------- |
| 0      | 16,24,96,16    | msg 0 "ID No."           | trainer id, right edge 112 (`0x60` rightX, ov51_021E74F4) |
| 1      | 136,24,104,16  | msg 1 "NAME"             | player name, right edge 240 (`0x68` rightX, ov51_021E7540) |
| 2      | 16,48,136,16   | msg 2 "MONEY"            | msg 19 `${STRVAR_1 55, 5, 0}` + BufferIntegerAsString(6 digits), right edge 152 |
| 3      | 16,72,136,16   | msg 3 "POKéDEX"          | msg 26 + BufferIntegerAsString(3 digits), right edge 152 — label AND value gated on info byte 4 bit 3 |
| 4      | 16,104,136,16  | msg 4 "SCORE"            | 9-digit value, right edge 152 |
| 5      | 16,128,224,16  | msg 5 "TIME"             | msg 20/21 (IGT or counters), right edge 240 |
| 6      | 16,144,224,16  | msg 6 "ADVENTURE STARTED"| msg 22 (day/month/year), right edge 240 |

The back-side windows (7..10, "HALL OF FAME DEBUT"/"TIMES LINKED"/"LINK
BATTLES"/"LINK TRADES") are printed by `ov51_021E7208` and copied to VRAM only
while the flip state `0x30F4` is set (`ov51_021E71D0`) — the flip/back side is
out of scope for the front-only viewer.

The label/value messages are msgdata bank 727 (`NewMsgDataFromNarc(0, 0x1b,
0x2d7)` at `ov51_021E5F64`; member 727 of `NARC_msgdata_msg` "a/0/2/7" — the
member index is the msgno; decoded with the project's `FieldMessageBank` +
`FieldMessageTokenizer`). Bank 727 messages 0..13 are the window labels;
messages 19/20/21/22/26 are the value templates; message 3 is "POKéDEX".

The trainer id is formatted by `String16_FormatInteger(..., 5 digits ...)`
(ov51_021E74F4) — five digits, zero-padded ("00000".."65535"), right edge x=112
on the y=24 row. The player name is right-aligned to x=240 on the same row.

## Close input and sound

`ov51_021E6A54` (the main-card input step): B (gSystem pressed bit 2) plays
`SEQ_SE_GS_GEARCANCEL` and returns state 5 (close); A (bit 1) plays
`SEQ_SE_DP_SELECT` and enters state 4 (the flip sub-state machine, out of
scope); L/R return state 3. This branch does not reproduce the card's
cancel effect: `TrainerCardController` requests no sound on close (the
Start Menu is silent too), so the effect catalogue entries
(`start_menu.cancel` = sequence 2368 = `SEQ_SE_GS_GEARCANCEL`) are not
compiled.

## Signature

The signature is 0x180 points (`TrainerCard_GetSignature`,
`src/save_trainer_card.c`) and is rendered as OAM sprites by the signature
editor overlay (`asm/overlay_trainer_card_signature.s`); the main-card
front-side code never draws it. The pixel-exact signature display rectangle is
sprite-position data not decoded here. The viewer reserves the bottom band of
the card front below the last audited text row (y=160..192) as
`TrainerCardRenderer.SIGNATURE_REGION`; the future signature editor owns that
band. The renderer never draws in it.

## Viewer decisions (deviations from a full source clone)

- The front labels ("ID No.", "NAME", "MONEY", "SCORE", "TIME", "ADVENTURE
  STARTED") and the text anchors live in the renderer as audited constants:
  they are the bank-727 window labels from the table above, and bank 727 is
  not part of the demo message selection, so no producer change was made to
  generate them. This is the same static-surface stance as the Start Menu:
  the menu's label plumbing was deleted because its renderer draws only the
  compiled background and cursor, so menu labels had no consumer; the card
  renderer does draw text, so it hard-codes the audited constants instead.
- The POKéDEX row is not drawn: its source label AND value are gated on a
  data bit (window 3 above), and the model always projects
  `pokedexOwned = nil` because no authoritative gameplay source for the bit
  exists yet, so the audited blank presentation omits the row.
- Money/play time/badges/pokedex/stars/signature are always nil in the current
  model (no authoritative gameplay source), so the viewer renders no value
  text and no value-formatting code exists (no dead branches).
- The card requests no sound: the branch does not reproduce the close
  effect, and the viewer keeps no effect wiring for a future audio branch.
- Back-side/flip interaction and the signature editor are out of scope for
  the front-only viewer (see "Card art" and "Signature" above).
