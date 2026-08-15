# HGSS field-UI asset sources

Evidence for the generated field-UI class (`FieldUiAssetCache`), pinned at the
same decomp commit the NARC catalog pins
(`7e25c842061d026f43fe6efbd7be0ec94c50839d`; the field-overlay asm files carry
the same blob). All member numbers are zero-based.

## Start Menu — `NARC_a_0_1_4` (a/0/1/4, narcId 14)

`src/start_menu.c:468-470` loads the menu background from members 12 (char),
13 (screen), 15 (palette) onto MAIN_3, and `src/start_menu.c:670-673` builds
the cursor from members 64 (char), 61 (palette), 62 (cell), 63 (animation).
The background screen is 256x192 (32x24 tiles); the touch handler
`src/start_menu.c:613-652` maps touch ids 1..10 (1 = cancel, 2..10 = the nine
display positions). `sActionToIconIndex` (`src/start_menu.c:161`) and the
`msg_0196_*` action labels are the icon/label authority for the later menu
work.

## Dialogue frames — `NARC_a_0_3_8` (a/0/3/8, narcId 38)

`LoadUserFrameGfx2` (arm9, `asm/render_window.s`) resolves the char member as
`frame + 2` (`sub_0200E63C`) and the palette member as `frame + 0x1A`
(`sub_0200E640`). Members 2..21 are the 20 frame char sets (18 tiles each in
the real dump) and members 26..45 the 20 frame palettes. The fixed frame
tilemap is composed by `DrawFrameAndWindow2` (`asm/render_window.s`), which
also owns the frame box geometry (2/19/27/4 tiles at 8px per
`src/dialog_box.c` DIALOG_BOX_* constants).

## Signposts — `NARC_a_0_3_6` (a/0/3/6, narcId 36)

`LoadMapSignpostFrameAndGraphic` (arm9, `asm/render_window.s`) loads the frame
char from member 0 and the frame palette from member 1, then for source
types 0 and 1 loads the wayfinding graphic from member `map + 0x21`
(type 0, `sub_0200EC84` +0x21 branch) or `map + 2` (type 1). The corpus scan
(`tests/rom/field_ui_assets_test.lua` sources; opcodes 55/56 of the real
scr_seq) uses types {0,1,2,3,4,5,8,9,10,11,13,15,16,17,18,19,20,21,23,28,29,
30,33,34,39} with (type,map) = (0,0),(0,1),(1,0),(1,1), i.e. wayfinding
members 33, 34, 2, 3. The wipe motion (BG y-offset -48, +16/frame) is
`src/field/signpost.c`.

## Trainer Card — `NARC_a_0_4_9` (a/0/4/9, narcId 49)

`asm/overlay_trainer_card_main.s` composes the card front from char member
0x29 (41), screen members 0x2F/0x35 (47/53), and palette members 0xB/0x1C/
0x2C/0x3C (11/28/44/60); the generated class currently bakes the front face
(char 41 + screen 47 + palette 11).

## Generated layout

`romdump/src/config/FieldUiAssets.lua` records every member number; the
generated manifest (`g4-field-ui-v2`) carries only semantic ids and
rectangles. No sound archive is selected: the source Start Menu effects
(SEQ_SE_DP_SELECT = 1500, SEQ_SE_DP_WIN_OPEN = 1532, SEQ_SE_GS_GEARCANCEL =
2368 in the pinned `sndseq.lua` catalog) are out of scope for this branch —
the branch does not reproduce them.
