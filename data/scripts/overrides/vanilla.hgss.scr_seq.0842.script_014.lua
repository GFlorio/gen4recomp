-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands replaced by a visible
-- placeholder dialogue. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script({
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
    {
      message = "msg.project.placeholder",
      op = "say",
      provenance = { offsets = { [1] = 5917 }, opcodes = { [1] = 55 } },
    },
    {
      message = "msg.project.placeholder",
      op = "say",
      provenance = { offsets = { [1] = 5934 }, opcodes = { [1] = 20 } },
    },
    { op = "stop", provenance = { offsets = { [1] = 5938 }, opcodes = { [1] = 2 } } },
  },
})
