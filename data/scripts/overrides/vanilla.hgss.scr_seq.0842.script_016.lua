-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands collapsed into explicit
-- unsupported nodes. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script {
  api = 1,
  id = "vanilla.hgss.scr_seq.0842.script_016",
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
      scriptIndex = 16,
    },
    coverage = { complete = true, unsupportedCount = 0 },
  },
  steps = {
    { op = "buffer_text", provenance = { offsets = { [1] = 4284 }, opcodes = { [1] = 192 } }, slot = 0, value = { text = "friend_name" } },
    { op = "signpost_set", provenance = { offsets = { [1] = 4287 }, opcodes = { [1] = 56 } }, sourceAppearance = { game = "hgss", map = 0, type = 2 } },
    { command = "wipe_in", op = "signpost_command", provenance = { offsets = { [1] = 4292 }, opcodes = { [1] = 57 } } },
    { op = "wait_signpost_action", provenance = { offsets = { [1] = 4295 }, opcodes = { [1] = 58 } } },
    { message = { bank = 542, id = 35, message = "external" }, op = "trainer_tips_print", provenance = { offsets = { [1] = 4297 }, opcodes = { [1] = 59 } }, result = { id = "VAR_SPECIAL_RESULT", value = "var" } },
    { op = "call_common", provenance = { offsets = { [1] = 4302 }, opcodes = { [1] = 20 } }, target = "common.signpost" },
    { op = "stop", provenance = { offsets = { [1] = 4306 }, opcodes = { [1] = 2 } } },
  },
}
