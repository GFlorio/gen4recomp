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
    {
      message = "msg.project.placeholder",
      op = "say",
      provenance = { offsets = { [1] = 10 }, opcodes = { [1] = 609 } },
    },
    { op = "lock_all", provenance = { offsets = { [1] = 12 }, opcodes = { [1] = 96 } } },
    { op = "play_sound", provenance = { offsets = { [1] = 14 }, opcodes = { [1] = 73 } }, sound = "SEQ_SE_DP_PC_ON" },
    {
      op = "buffer_text",
      provenance = { offsets = { [1] = 18 }, opcodes = { [1] = 190 } },
      slot = 0,
      value = { text = "player_name" },
    },
    {
      message = "msg.hgss.0546.00000",
      op = "message",
      provenance = { offsets = { [1] = 21 }, opcodes = { [1] = 45 } },
      style = "npc",
      waitForPrint = true,
    },
    { erase = true, op = "close_message", provenance = { offsets = { [1] = 24 }, opcodes = { [1] = 53 } } },
    {
      message = "msg.project.placeholder",
      op = "say",
      provenance = { offsets = { [1] = 26 }, opcodes = { [1] = 377 } },
    },
    {
      condition = {
        condition = "compare",
        left = { id = "VAR_SPECIAL_RESULT", value = "var" },
        operator = "eq",
        right = 0,
      },
      op = "goto_if",
      provenance = { offsets = { [1] = 30, [2] = 36 }, opcodes = { [1] = 17, [2] = 28 } },
      target = "_004B",
    },
    {
      color = "black",
      direction = "out",
      kind = 6,
      op = "fade_screen",
      provenance = { offsets = { [1] = 43 }, opcodes = { [1] = 174 } },
      speed = 1,
    },
    { op = "wait_fade", provenance = { offsets = { [1] = 53 }, opcodes = { [1] = 175 } } },
    {
      message = "msg.project.placeholder",
      op = "say",
      provenance = { offsets = { [1] = 55 }, opcodes = { [1] = 376 } },
    },
    {
      color = "black",
      direction = "in",
      kind = 6,
      op = "fade_screen",
      provenance = { offsets = { [1] = 59 }, opcodes = { [1] = 174 } },
      speed = 1,
    },
    { op = "wait_fade", provenance = { offsets = { [1] = 69 }, opcodes = { [1] = 175 } } },
    { op = "release_all", provenance = { offsets = { [1] = 71 }, opcodes = { [1] = 97 } } },
    { op = "yield_tick" },
    { op = "stop", provenance = { offsets = { [1] = 73 }, opcodes = { [1] = 2 } } },
    { name = "_004B", op = "label" },
    {
      message = "msg.hgss.0546.00001",
      op = "say",
      provenance = { offsets = { [1] = 75, [2] = 78, [3] = 80 }, opcodes = { [1] = 45, [2] = 50, [3] = 53 } },
    },
    { op = "release_all", provenance = { offsets = { [1] = 82 }, opcodes = { [1] = 97 } } },
    { op = "yield_tick" },
    { op = "stop", provenance = { offsets = { [1] = 84 }, opcodes = { [1] = 2 } } },
  },
})
