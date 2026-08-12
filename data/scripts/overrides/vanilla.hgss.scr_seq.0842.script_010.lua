-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands collapsed into explicit
-- unsupported nodes. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script {
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
    { arguments = { [1] = "VAR_SPECIAL_RESULT" }, command = 729, op = "unsupported", originalName = "ScrCmd_729", provenance = { offsets = { [1] = 4180 }, opcodes = { [1] = 729 } } },
    { condition = { condition = "compare", left = { id = "VAR_SPECIAL_RESULT", value = "var" }, operator = "eq", right = 0 }, op = "goto_if", provenance = { offsets = { [1] = 4184, [2] = 4190 }, opcodes = { [1] = 17, [2] = 28 } }, target = "_1078" },
    { arguments = { [1] = "VAR_SPECIAL_RESULT" }, command = 596, op = "unsupported", originalName = "ScrCmd_596", provenance = { offsets = { [1] = 4197 }, opcodes = { [1] = 596 } } },
    { condition = { condition = "compare", left = { id = "VAR_SPECIAL_RESULT", value = "var" }, operator = "ne", right = 1 }, op = "goto_if", provenance = { offsets = { [1] = 4201, [2] = 4207 }, opcodes = { [1] = 17, [2] = 28 } }, target = "_1078" },
    { arguments = {}, command = 600, op = "unsupported", originalName = "ScrCmd_600", provenance = { offsets = { [1] = 4214 }, opcodes = { [1] = 600 } } },
    { name = "_1078", op = "label" },
    { op = "play_sound", provenance = { offsets = { [1] = 4216 }, opcodes = { [1] = 73 } }, sound = "SEQ_SE_DP_KAIDAN2" },
    { color = "black", direction = "out", kind = 6, op = "fade_screen", provenance = { offsets = { [1] = 4220 }, opcodes = { [1] = 174 } }, speed = 1 },
    { op = "wait_fade", provenance = { offsets = { [1] = 4230 }, opcodes = { [1] = 175 } } },
    { facing = "west", fieldX = 12, fieldZ = 6, map = "MAP_T20R0102", op = "warp", provenance = { offsets = { [1] = 4232 }, opcodes = { [1] = 176 } }, warp = 0 },
    { color = "black", direction = "in", kind = 6, op = "fade_screen", provenance = { offsets = { [1] = 4244 }, opcodes = { [1] = 174 } }, speed = 1 },
    { op = "wait_fade", provenance = { offsets = { [1] = 4254 }, opcodes = { [1] = 175 } } },
    { op = "wait_sound", provenance = { offsets = { [1] = 4256 }, opcodes = { [1] = 75 } }, sound = "SEQ_SE_DP_KAIDAN2" },
    { arguments = { [1] = 60, [2] = 688, [3] = 393 }, command = 582, op = "unsupported", originalName = "ScrCmd_582", provenance = { offsets = { [1] = 4260 }, opcodes = { [1] = 582 } } },
    { op = "set_var", provenance = { offsets = { [1] = 4268 }, opcodes = { [1] = 41 } }, value = 1, variable = { id = "VAR_UNK_407C", value = "var" } },
    { op = "stop", provenance = { offsets = { [1] = 4274 }, opcodes = { [1] = 2 } } },
  },
}
