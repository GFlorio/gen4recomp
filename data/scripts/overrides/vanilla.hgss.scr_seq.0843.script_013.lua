-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands replaced by a visible
-- placeholder dialogue. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "vanilla.hgss.scr_seq.0843.script_013",
  metadata = {
    override = true,
    generated = true,
    generator = { name = "hgss-script-translator", version = 1 },
    source = {
      repository = "g4recomp",
      path = "romfs/scr_seq.narc",
      game = "heartgold",
      archive = "scr_seq",
      member = 843,
      scriptIndex = 13,
    },
    coverage = { complete = false, unsupportedCount = 2 },
  },
  steps = {
    S.playSound({ provenance = { offsets = { 4274 }, opcodes = { 73 } }, sound = "SEQ_SE_DP_SELECT" }),
    S.lockAll(),
    S.gotoIf(S.not_(S.flag("FLAG_GOT_STARTER")), "_1107"),
    S.message({
      message = "msg.hgss.0543.00092",
      provenance = { offsets = { 4293 }, opcodes = { 45 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4296 }, opcodes = { 746 } } }),
    S.closeMessage({ erase = true, provenance = { offsets = { 4304 }, opcodes = { 53 } } }),
    S.gotoIf(S.eq(S.var("VAR_SPECIAL_RESULT"), 1), "_1103"),
    S.fadeScreen({
      color = "black",
      direction = "out",
      kind = 6,
      provenance = { offsets = { 4319 }, opcodes = { 174 } },
      speed = 1,
    }),
    S.waitFade(),
    S.playFanfare({ fanfare = "SEQ_ME_ASA", provenance = { offsets = { 4331 }, opcodes = { 78 } } }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4335 }, opcodes = { 282 } } }),
    S.waitFanfare(),
    S.fadeScreen({
      color = "black",
      direction = "in",
      kind = 6,
      provenance = { offsets = { 4343 }, opcodes = { 174 } },
      speed = 1,
    }),
    S.waitFade(),
    S.label("_1103"),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
    S.label("_1107"),
    S.say({
      message = "msg.hgss.0543.00014",
      provenance = { offsets = { 4359, 4362, 4364 }, opcodes = { 45, 50, 53 } },
    }),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
  },
})
