-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands collapsed into explicit
-- unsupported nodes. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script {
  api = 1,
  id = "vanilla.hgss.scr_seq.0842.script_007",
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
      scriptIndex = 7,
    },
    coverage = { complete = false, unsupportedCount = 2 },
  },
  steps = {
    { op = "buffer_text", provenance = { offsets = { [1] = 3796 }, opcodes = { [1] = 190 } }, slot = 0, value = { text = "player_name" } },
    { op = "signpost_set", provenance = { offsets = { [1] = 3799 }, opcodes = { [1] = 56 } }, sourceAppearance = { game = "hgss", map = 0, type = 2 } },
    { command = "wipe_in", op = "signpost_command", provenance = { offsets = { [1] = 3804 }, opcodes = { [1] = 57 } } },
    { op = "wait_signpost_action", provenance = { offsets = { [1] = 3807 }, opcodes = { [1] = 58 } } },
    { arguments = { [1] = 35, [2] = "VAR_SPECIAL_RESULT" }, command = 59, op = "unsupported", originalName = "ScrCmd_TrainerTips", provenance = { offsets = { [1] = 3809 }, opcodes = { [1] = 59 } } },
    { arguments = {}, command = 0, op = "unsupported", originalName = "call to unsupported script common.signpost", provenance = { offsets = { [1] = 3814 }, opcodes = { [1] = 20 } } },
    { op = "stop", provenance = { offsets = { [1] = 3818 }, opcodes = { [1] = 2 } } },
  },
}
