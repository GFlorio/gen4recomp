# HGSS signpost command contracts (script opcodes 55–60)

Source audit for the signpost script command family. All decomp evidence is
pinned to pret/pokeheartgold commit `dfdbbdf3273545ca35456d69bcb0ee3403f76450`
(the commit the in-repo reference catalogs pin), with the current C rewrite
cited where it names the constants.

## Wire formats

`asm/macros/script.inc` defines the macros:

| Opcode | Macro | Emission |
| -----: | ----- | -------- |
| 55 | `DirectionSignpost message, arg1, arrow, arg3` | `.short 55`, `.byte \message`, `.byte \arg1`, `.short \arrow`, `.short \arg3` |
| 56 | `ScrCmd_056 message, arg1` | `.short 56`, `.byte \message`, `.short \arg1` |
| 57 | `ScrCmd_057 arg0` | `.short 57`, `.byte \arg0` |
| 58 | `ScrCmd_058` | `.short 58` |
| 59 | `TrainerTips arg0, arg1` | `.short 59`, `.byte \arg0`, `.short \arg1` |
| 60 | `ScrCmd_060 arg0` | `.short 60`, `.short \arg0` |

The repository catalog `romdump/src/reference/hgss/script_commands.lua`
records these as widths `{1,1,2,2}`, `{1,2}`, `{1}`, `{}`, `{1,2}`, `{2}`.

## Command constants 0..4

`asm/signpost.s` (`Signpost_DoCurrentCommand`) dispatches on the signpost
command through a five-case jump table at 0x021F3DB2:

- case 0: no work, returns (NOP)
- case 1: `ov01_021F3E10` (create window, load frame/graphic), then clears the
  command (SHOW)
- case 2: `ov01_021F3EE0`; on endpoint observation (returns 1) clears the
  command (WIPE_OUT)
- case 3: `ov01_021F3EA0`; on endpoint observation clears the command (WIPE_IN)
- case 4: `ov01_021F3E4C` (remove window, clear tile area), then clears the
  command (HIDE)

The current C rewrite names the values in `include/constants/scrcmd.h`
(`MAPSIGNCOMMAND_NOP 0`, `MAPSIGNCOMMAND_SHOW 1`, `MAPSIGNCOMMAND_WIPE_OUT 2`,
`MAPSIGNCOMMAND_WIPE_IN 3`, `MAPSIGNCOMMAND_HIDE 4`) and confirms in
`src/field/signpost.c` that `Signpost_SetCommand` is a bare assignment with no
busy guard. The five names are recorded in
`romdump/src/reference/hgss/signpost_commands.lua`.

## Real-script fixtures

The HeartGold script corpus (scr_seq.narc) contains compiled uses of every
opcode and of the macro compositions:

- TrainerTipsEx composition (member 9 script 0):
  `SetSignpostMap 2,0; SetSignpostAction 3; WaitSignpostAction; TrainerTips 0,
  VAR_SPECIAL_RESULT; CallStd 2000`.
- DirectionSignpostEx composition (member 168 script 2):
  `DirectionSignpost 0,1,4,VAR_SPECIAL_RESULT; SetSignpostAction 3;
  WaitSignpostAction; WaitSignpost VAR_SPECIAL_RESULT; CallStd 2000`.
- `std_signpost` (CallStd 2000, member 3 script 0) drives cleanup from the
  special result: `SetSignpostAction 2` (WIPE_OUT) for results 0 and 2,
  `SetSignpostAction 4` (HIDE) for result 1, then `WaitSignpostAction`,
  `ScrCmd_061`, restart.

The opcode-55 last operand is decoded and preserved but never written
(`DirectionSignpost` emits it into `VAR_SPECIAL_RESULT` only by convention;
the runtime work must not make it meaningful).

## Opcode 61 — the std_signpost context end

`std_signpost`'s hide branch (special result 1) tails with `ScrCmd_061`, and
the real `common.signpost` child must be fully supported for the integration
(an unsupported node in it keeps every `CallStd 2000` call collapsed into a
loud override fault). Audited semantics (all at the pinned commit):

- `src/scrcmd_c.c:945-948`:
  `BOOL ScrCmd_061(ScriptContext *ctx) { sub_0204031C(ctx->fieldSystem); return FALSE; }`
  — no operands (the catalog widths `{}` are correct), and returning FALSE
  ends the current script context.
- `src/script_manager.c:334-339` (`sub_0204031C`): installs
  `unk->scrctx_end_cb = sub_0203BD64` on the script environment (unless the
  map is a mystery zone).
- `src/start_menu.c:256+` (`sub_0203BD64`): plays `SEQ_SE_DP_WIN_OPEN` and
  opens the Start Menu task with the context-appropriate inhibit flags.
- `src/script_manager.c:128-140`: the end callback fires when
  `activeScriptContextCount == 0` — i.e. when the whole script environment
  (parent plus child contexts) has ended, which is the "restart" behavior
  the earlier `std_signpost` corpus note observed.

The corpus census (decoder probe over all scripts) shows opcode 61 appears
exactly once — `common.signpost` at offset 1250, the hide branch — and every
`CallStd 2000` caller's last `VAR_SPECIAL_RESULT` write is opcode 59 or
55/60 (values 0 or 2 only), so the hide branch is unreachable in retail
usage. Faithful runtime support is nevertheless wired: the catalog classifies
61 as `stop`, `SemanticLowering` emits the terminal
`{ op = "request_start_menu" }` node, and the runtime handler routes the
reopen request through the `startMenuReopen` service (an attributed
`SCRIPT_SERVICE_MISSING` fault when no Start Menu host is wired — never a
silent close) and returns the stop outcome that ends the script context. The
moment the request is delivered (the source delivers at environment end) is
the Start Menu application host's composition decision (the runtime consumes
the queued request at its post-scheduler arbitration point).

## Signal_caller ends the context

The wipe-out branches never reach 61 because each branch ends with
`RestartCurrentScript` — and `ScrCmd_RestartCurrentScript`
(`src/scrcmd_c.c:378-388`) toggles the caller signal bit and **returns
FALSE**, ending the script context. The trailing `End` in the source
(`_04D6: ScrCmd_057 2; RestartCurrentScript; End`) is dead code: the
decoder terminates the run at opcode 21 and drops the following `End` as
alignment padding before the next justified label (the same mechanism that
drops the script-final `End`), so the translated child must end at
`signal_caller`, never fall through to the next branch region. The runtime
`signal_caller` handler returns the stop outcome and the compiler gives the
signal node no next edge, matching the source; `std_signpost`'s hide branch
is reachable only through its goto targets.
