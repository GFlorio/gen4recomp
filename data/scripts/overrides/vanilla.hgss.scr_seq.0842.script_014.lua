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
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5917 }, opcodes = { 55 } } }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5934 }, opcodes = { 20 } } }),
    S.stop(),
  },
})
