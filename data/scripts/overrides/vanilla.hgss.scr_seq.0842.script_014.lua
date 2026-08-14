-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands collapsed into explicit
-- unsupported nodes. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script {
  api = 1,
  id = "vanilla.hgss.scr_seq.0842.script_014",
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
      scriptIndex = 14,
    },
    coverage = { complete = false, unsupportedCount = 2 },
  },
  steps = {
    { message = { bank = 542, id = 34, message = "external" }, op = "signpost_direction", provenance = { offsets = { [1] = 5917 }, opcodes = { [1] = 55 } }, sourceAppearance = { game = "hgss", map = 11, type = 0 }, sourceUnusedOut = "VAR_SPECIAL_RESULT" },
    { command = "wipe_in", op = "signpost_command", provenance = { offsets = { [1] = 5925 }, opcodes = { [1] = 57 } } },
    { op = "wait_signpost_action", provenance = { offsets = { [1] = 5928 }, opcodes = { [1] = 58 } } },
    { arguments = { [1] = "VAR_SPECIAL_RESULT" }, command = 60, op = "unsupported", originalName = "ScrCmd_WaitSignpost", provenance = { offsets = { [1] = 5930 }, opcodes = { [1] = 60 } } },
    { arguments = {}, command = 0, op = "unsupported", originalName = "call to unsupported script common.signpost", provenance = { offsets = { [1] = 5934 }, opcodes = { [1] = 20 } } },
    { op = "stop", provenance = { offsets = { [1] = 5938 }, opcodes = { [1] = 2 } } },
  },
}
