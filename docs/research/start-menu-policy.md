# HGSS Start Menu action policy

Source audit for the pure `StartMenuPolicy` module (action definitions,
context inhibit masks, progression gates, availability gates). All decomp
evidence is pinned to pret/pokeheartgold commit `008257708` (Merge pull
request #501; the checkout in `/workspace/tmp/refs/pokeheartgold`). The
in-repo reference catalogs pin the older `7e25c842`; every claim below was
re-verified against the pinned checkout.

## Canonical actions

`src/start_menu.c:49-63` — the `StartMenuAction` enum, in order:

    POKEDEX, POKEMON, BAG, TRAINER_CARD, SAVE, OPTIONS, RUNNING_SHOES, 7,
    RETIRE, 9, 10, POKEGEAR, 12

`src/start_menu.c:65-76` — the `StartMenuActionDisable` inhibit-bit enum:
POKEDEX, POKEMON, BAG, TRAINER_CARD, SAVE, OPTIONS, RUNNING_SHOES, 7,
RETIRE, POKEGEAR. Note there is no inhibit bit for 9, 10, or 12: those three
can never be inhibited by a context mask.

Labels — `src/start_menu.c:176-190` `sStartMenuActions`, the `ident` field:
POKEDEX `msg_0196_00000`, POKEMON `msg_0196_00001`, BAG `msg_0196_00002`,
TRAINER_CARD `msg_0196_00003`, SAVE `msg_0196_00004`, OPTIONS
`msg_0196_00005`, RUNNING_SHOES `msg_0196_00006`, 7 `msg_0196_00007`,
RETIRE `msg_0196_00008`, and `msg_0196_00014` for the whole Pokégear family
(9, 10, POKEGEAR, 12) — Trainer Card `00003`, Options `00005`, Pokégear
family `00014`.

Icons — `src/start_menu.c:161-174` `sActionToIconIndex`:
`{0, 1, 2, 4, 5, 6, 100, 100, 100, 100, 100, 3}` — POKEDEX 0, POKEMON 1,
BAG 2, POKEGEAR 3, TRAINER_CARD 4, SAVE 5, OPTIONS 6; RUNNING_SHOES, 7,
RETIRE, 9, 10 are 100 ("no icon"). Quirk: the reconstructed table has 12
entries for the 13-action enum, so `sActionToIconIndex[START_MENU_ACTION_12]`
is out of bounds of the reconstructed table; the producer's compiled
`startMenu.icons` manifest mapping (the generated class already carries it) is the runtime authority,
and the policy does not carry icons.

Handlers (selection routing, useful reference for the later controller work): Pokedex/Pokemon/Bag/
TrainerCard/Save/Options handlers (`src/start_menu.c:177-182`),
RUNNING_SHOES = `STARTMENUTASKFUNC_CANCEL` (cancel sound + close,
`src/start_menu.c:183`), 7 = `RemovedEasyChatThing` (`src/start_menu.c:184`),
RETIRE (`src/start_menu.c:185`), 9/10/POKEGEAR = the Pokegear handler
(`src/start_menu.c:186-188`), 12 = `sub_0203D2CC`
(`src/start_menu.c:189`, `src/start_menu.c:1158-1162`: sets field state 19).

## Context selection

`StartMenu_Init` (`src/start_menu.c:216-234`): Safari sysflag →
`..._Safari`; Bug Contest flag → `..._BugContest`; Pal Park sysflag →
`..._PalPark`; Battle Tower partner room map check →
`..._BattleTowerMultiPartnerSelectRoom`; else `..._Normal`. The script-driven
reopen `sub_0203BD64` (`src/start_menu.c:256-277`) repeats that chain and
adds the `MAP_LOAD_TYPE_COLOSSEUM` / `MAP_LOAD_TYPE_UNION` branches (this is
the opcode-61 `request_start_menu` reopen route, per the script-command
handoff). The
dedicated entry helpers `sub_0203BCDC` (union, `unk_350 = TRUE`,
`src/start_menu.c:236-244`) and `sub_0203BD20` (colosseum,
`unk_350 = FALSE`, `src/start_menu.c:246-254`) set the same masks.
`MAP_LOAD_TYPE_UNION`/`MAP_LOAD_TYPE_COLOSSEUM` are
`include/constants/field/map_load.h:7-8` (values 1 and 2).

Context flags: `FLAG_SYS_SAFARI` 0x967 and `FLAG_SYS_PAL_PARK` 0x971
(`include/constants/flags.h:1713,1723`), the Bug Contest check is
`FLAG_UNK_996` (`src/sys_flags.c:216-218`). The policy never reads these:
the game-side adapter maps them to a named context.

## Inhibit masks (list presence)

All in `src/start_menu.c`; each context function returns the full mask (the
special contexts replace the normal mask entirely — progression gates do not
apply in them):

| Context | Function | Mask |
| ------- | -------- | ---- |
| normal_field | `..._Normal` 288-307 | POKEDEX unless `CheckGotPokedex`, POKEMON unless `CheckGotStarter`, BAG unless `CheckGotMenuIconI(UNLOCK_BAG)`, POKEGEAR unless `CheckGotPokegear`, Amity Square check → POKEMON\|BAG, always 7\|RETIRE |
| safari | `..._Safari` 309-311 | SAVE\|7 |
| bug_contest | `..._BugContest` 313-315 | BAG\|SAVE\|7 |
| pal_park | `..._PalPark` 317-319 | BAG\|SAVE\|7 |
| battle_tower_partner_room | `..._BattleTowerMultiPartnerSelectRoom` 321-323 | POKEDEX\|BAG\|SAVE\|7\|RETIRE\|POKEGEAR |
| union_room | `sub_0203BEE0` 325-327 | SAVE\|RETIRE, plus `unk_350` (action 12 replaces POKEGEAR in its slot) |
| colosseum | `sub_0203BEE8` 329-331 | POKEDEX\|SAVE\|7\|RETIRE\|POKEGEAR |

`FieldSystem_GetStartMenuButtonInhibitFlags_Normal` uses the four
`CheckGot*` gates (sys_flags.c:273-289) and the `MapHeader_MapIsAmitySquare`
check. `MapHeader_MapIsAmitySquare` (`src/map_header.c:222-224`) is
**dead code in retail**: it always returns FALSE, with the comment "Leftover
from D/P/Pl." — no retail play can reach the Amity Square inhibit. The
`amity_square` policy context nevertheless implements the source's mask
structure for it (normal gates + unconditional POKEMON|BAG), so the model
matches what the code would do if the check were live.

`FieldSystem_MapIsBattleTowerMultiPartnerSelectRoom` is declared in
`include/unk_02066EDC.h:16`; the mask is applied when it returns TRUE.

## Build sequence

`StartMenu_BuildActionLists` (`src/start_menu.c:483-523`), insertion order:
RETIRE, 7, POKEDEX, POKEMON, BAG, POKEGEAR-or-12, TRAINER_CARD, SAVE,
OPTIONS, RUNNING_SHOES (each gated by its inhibit bit), then 9 at display
position 7 and 10 at display position 8 unconditionally. The POKEGEAR slot
inserts `START_MENU_ACTION_12` instead of POKEGEAR when `unk_350` is set
(union room). `StartMenuButton_Insert` (`src/start_menu.c:474-481`) appends
to `insertionOrder` and writes the given display position (append = current
count; 9/10 = fixed 7/8). The task state arrays are
`u8 insertionOrder[10]` / `u8 selectionToAction[10]`
(`include/start_menu.h:51-52`), so the built list never exceeds 10 entries
— verified for every context mask above (max 10 in normal full progression
and union room).

The policy emits the insertion order with `displayPosition` per entry (the
source's display array writes; 9/10 keep 7/8 even when earlier entries are
absent). The display-array overwrite behavior (9/10 overwrite whatever
landed at display 7/8) is the controller's composition step against
the generated slot metadata, not the policy's.

## Availability gate (vanillaEnabled, "present but unavailable")

`FieldSystem_StartMenuActionIsAvailable` (`src/start_menu.c:531-533`) →
`FieldSystem_ShouldDrawStartMenuIcon` (`src/start_menu.c:535-556`), keyed by
the action's icon index:

| Action | Icon | Availability |
| ------ | ---- | ------------ |
| POKEDEX | 0 | `CheckGotPokedex` |
| POKEMON | 1 | `CheckGotStarter` |
| BAG | 2 | `CheckGotMenuIconI(UNLOCK_BAG)` |
| POKEGEAR | 3 | `CheckGotPokegear` |
| TRAINER_CARD | 4 | `CheckGotMenuIconI(UNLOCK_TRAINER_CARD)` |
| SAVE | 5 | `CheckGotMenuIconI(UNLOCK_SAVE_BUTTON)` |
| OPTIONS | 6 | `CheckGotMenuIconI(UNLOCK_OPTIONS_BUTTON)` |
| RUNNING_SHOES | 100 | default TRUE — the `START_MENU_ICON_RUNNING_SHOES` case (`PlayerSaveData_CheckRunningShoes`, `src/player_avatar.c:453-457`) is **unreachable** from the action path because the action's icon index is 100, not 7 |
| 7, RETIRE, 9, 10, 12 | 100 | default TRUE |

Unlock ids: `include/constants/start_menu_icons.h:4-7`
(UNLOCK_BAG 0, TRAINER_CARD 1, SAVE_BUTTON 2, OPTIONS_BUTTON 3), checked as
`FLAG_GOT_BAG + idx` (`FLAG_GOT_BAG` 0x11B, `include/constants/flags.h:302`).
The other unlock flags are `FLAG_GOT_TRAINER_CARD` 0x11C,
`FLAG_GOT_SAVE_BUTTON` 0x11D, `FLAG_GOT_OPTIONS_BUTTON` 0x11E
(`include/constants/flags.h:303-305`); progression gates are
`FLAG_GOT_STARTER` 0x6A, `FLAG_GOT_POKEDEX` 0x6B, `FLAG_GOT_POKEGEAR` 0x9C
(`include/constants/flags.h:125-126,175`), via `CheckGotStarter`/
`CheckGotPokegear`/`CheckGotPokedex`/`CheckGotMenuIconI`
(`src/sys_flags.c:273-289`).

Policy consequence (the present-vs-unavailable distinction): the four
CheckGot-gated actions derive `vanillaEnabled` from the strict snapshot's
progression booleans; TRAINER_CARD/SAVE/OPTIONS/RUNNING_SHOES and the
special actions are modeled as canonically available constants because (a)
their gates are sysflags/player-save data the pinned snapshot does not
carry, and (b) the canonical game sets the four `FLAG_GOT_BAG+idx` unlocks
in the very first scripted conversation (`files/fielddata/script/scr_seq/
scr_seq_0845_T20R0201.s:29,36,42,48`), and the RUNNING_SHOES gate is
unreachable via the action path (icon 100 → default TRUE).

## Message bank

The label refs are pure refs (`msg.hgss.0196.000XX`); bank 0196 is absent
from the demo generated message cache (banks dir holds 0191, 0542-0549), so
no producer bank-selection change is part of this deliverable. Resolution
through `FieldMessageProvider` is the menu composition step's work: "The
Start Menu composition step resolves them through `FieldMessageProvider`
before constructing the controller".
