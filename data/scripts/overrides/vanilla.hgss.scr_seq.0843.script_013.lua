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
    {
      op = "play_sound",
      provenance = { offsets = { [1] = 4274 }, opcodes = { [1] = 73 } },
      sound = "SEQ_SE_DP_SELECT",
    },
    { op = "lock_all", provenance = { offsets = { [1] = 4278 }, opcodes = { [1] = 96 } } },
    {
      condition = { condition = "flag", expected = false, id = "FLAG_GOT_STARTER" },
      op = "goto_if",
      provenance = { offsets = { [1] = 4282, [2] = 4286 }, opcodes = { [1] = 32, [2] = 28 } },
      target = "_1107",
    },
    {
      message = "msg.hgss.0543.00092",
      op = "message",
      provenance = { offsets = { [1] = 4293 }, opcodes = { [1] = 45 } },
      waitForPrint = true,
    },
    {
      op = "set_auxiliary_ui_visible",
      provenance = { offsets = { [1] = 4296 }, opcodes = { [1] = 746 } },
      visible = false,
    },
    { erase = true, op = "close_message", provenance = { offsets = { [1] = 4304 }, opcodes = { [1] = 53 } } },
    {
      condition = {
        condition = "compare",
        left = { id = "VAR_SPECIAL_RESULT", value = "var" },
        operator = "eq",
        right = 1,
      },
      op = "goto_if",
      provenance = { offsets = { [1] = 4306, [2] = 4312 }, opcodes = { [1] = 17, [2] = 28 } },
      target = "_1103",
    },
    {
      color = "black",
      direction = "out",
      kind = 6,
      op = "fade_screen",
      provenance = { offsets = { [1] = 4319 }, opcodes = { [1] = 174 } },
      speed = 1,
    },
    { op = "wait_fade", provenance = { offsets = { [1] = 4329 }, opcodes = { [1] = 175 } } },
    { fanfare = "SEQ_ME_ASA", op = "play_fanfare", provenance = { offsets = { [1] = 4331 }, opcodes = { [1] = 78 } } },
    {
      message = "msg.project.placeholder",
      op = "say",
      provenance = { offsets = { [1] = 4335 }, opcodes = { [1] = 282 } },
    },
    { op = "wait_fanfare", provenance = { offsets = { [1] = 4341 }, opcodes = { [1] = 79 } } },
    {
      color = "black",
      direction = "in",
      kind = 6,
      op = "fade_screen",
      provenance = { offsets = { [1] = 4343 }, opcodes = { [1] = 174 } },
      speed = 1,
    },
    { op = "wait_fade", provenance = { offsets = { [1] = 4353 }, opcodes = { [1] = 175 } } },
    { name = "_1103", op = "label" },
    { op = "release_all", provenance = { offsets = { [1] = 4355 }, opcodes = { [1] = 97 } } },
    { op = "yield_tick" },
    { op = "stop", provenance = { offsets = { [1] = 4357 }, opcodes = { [1] = 2 } } },
    { name = "_1107", op = "label" },
    {
      message = "msg.hgss.0543.00014",
      op = "say",
      provenance = { offsets = { [1] = 4359, [2] = 4362, [3] = 4364 }, opcodes = { [1] = 45, [2] = 50, [3] = 53 } },
    },
    { op = "release_all", provenance = { offsets = { [1] = 4366 }, opcodes = { [1] = 97 } } },
    { op = "yield_tick" },
    { op = "stop", provenance = { offsets = { [1] = 4368 }, opcodes = { [1] = 2 } } },
  },
})
