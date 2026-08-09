-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands replaced by a visible
-- placeholder dialogue. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "vanilla.hgss.scr_seq.0846.script_000",
  metadata = {
    override = true,
    generated = true,
    generator = { name = "hgss-script-translator", version = 1 },
    source = {
      repository = "g4recomp",
      path = "romfs/scr_seq.narc",
      game = "heartgold",
      archive = "scr_seq",
      member = 846,
      scriptIndex = 0,
    },
    coverage = { complete = false, unsupportedCount = 3 },
  },
  steps = {
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 10 }, opcodes = { 609 } } }),
    S.lockAll(),
    S.playSound({ provenance = { offsets = { 14 }, opcodes = { 73 } }, sound = "SEQ_SE_DP_PC_ON" }),
    S.bufferText({ provenance = { offsets = { 18 }, opcodes = { 190 } }, slot = 0, value = { text = "player_name" } }),
    S.message({
      message = "msg.hgss.0546.00000",
      provenance = { offsets = { 21 }, opcodes = { 45 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 24 }, opcodes = { 53 } } }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 26 }, opcodes = { 377 } } }),
    S.gotoIf(S.eq(S.var("VAR_SPECIAL_RESULT"), 0), "_004B"),
    S.fadeScreen({
      color = "black",
      direction = "out",
      kind = 6,
      provenance = { offsets = { 43 }, opcodes = { 174 } },
      speed = 1,
    }),
    S.waitFade(),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 55 }, opcodes = { 376 } } }),
    S.fadeScreen({
      color = "black",
      direction = "in",
      kind = 6,
      provenance = { offsets = { 59 }, opcodes = { 174 } },
      speed = 1,
    }),
    S.waitFade(),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
    S.label("_004B"),
    S.say({ message = "msg.hgss.0546.00001", provenance = { offsets = { 75, 78, 80 }, opcodes = { 45, 50, 53 } } }),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
  },
})
