-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands replaced by a visible
-- placeholder dialogue. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "vanilla.hgss.scr_seq.0842.script_010",
  metadata = {
    override = true,
    generated = true,
    generator = { name = "hgss-script-translator", version = 1 },
    source = {
      repository = "g4recomp",
      path = "romfs/scr_seq.narc",
      game = "heartgold",
      archive = "scr_seq",
      member = 842,
      scriptIndex = 10,
    },
    coverage = { complete = false, unsupportedCount = 4 },
  },
  steps = {
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4180 }, opcodes = { 729 } } }),
    S.gotoIf(S.eq(S.var("VAR_SPECIAL_RESULT"), 0), "_1078"),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4197 }, opcodes = { 596 } } }),
    S.gotoIf(S.ne(S.var("VAR_SPECIAL_RESULT"), 1), "_1078"),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4214 }, opcodes = { 600 } } }),
    S.label("_1078"),
    S.playSound({ provenance = { offsets = { 4216 }, opcodes = { 73 } }, sound = "SEQ_SE_DP_KAIDAN2" }),
    S.fadeScreen({
      color = "black",
      direction = "out",
      kind = 6,
      provenance = { offsets = { 4220 }, opcodes = { 174 } },
      speed = 1,
    }),
    S.waitFade(),
    S.warp({
      facing = "west",
      fieldX = 12,
      fieldZ = 6,
      map = "MAP_T20R0102",
      provenance = { offsets = { 4232 }, opcodes = { 176 } },
      warp = 0,
    }),
    S.fadeScreen({
      color = "black",
      direction = "in",
      kind = 6,
      provenance = { offsets = { 4244 }, opcodes = { 174 } },
      speed = 1,
    }),
    S.waitFade(),
    S.waitSound({ provenance = { offsets = { 4256 }, opcodes = { 75 } }, sound = "SEQ_SE_DP_KAIDAN2" }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4260 }, opcodes = { 582 } } }),
    S.setVar({ provenance = { offsets = { 4268 }, opcodes = { 41 } }, value = 1, variable = S.var("VAR_UNK_407C") }),
    S.stop(),
  },
})
