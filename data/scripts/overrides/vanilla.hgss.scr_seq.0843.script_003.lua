-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands replaced by a visible
-- placeholder dialogue. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "vanilla.hgss.scr_seq.0843.script_003",
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
      scriptIndex = 3,
    },
    coverage = { complete = false, unsupportedCount = 3 },
  },
  steps = {
    {
      message = "msg.project.placeholder",
      op = "say",
      provenance = { offsets = { [1] = 1636 }, opcodes = { [1] = 609 } },
    },
    { op = "lock_all", provenance = { offsets = { [1] = 1638 }, opcodes = { [1] = 96 } } },
    {
      op = "get_player_coords",
      provenance = { offsets = { [1] = 1640 }, opcodes = { [1] = 105 } },
      x = { id = "VAR_BASE", value = "var" },
      z = { id = "VAR_TEMP_x4001", value = "var" },
    },
    {
      condition = { condition = "compare", left = { id = "VAR_BASE", value = "var" }, operator = "eq", right = 3 },
      no = {
        [1] = {
          condition = { condition = "compare", left = { id = "VAR_BASE", value = "var" }, operator = "ne", right = 4 },
          op = "goto_if",
          provenance = { offsets = { [1] = 1673, [2] = 1679 }, opcodes = { [1] = 17, [2] = 28 } },
          target = "_06A4",
        },
        [2] = {
          actor = { mapIndex = 2, ref = "actor" },
          movement = {
            [1] = { action = "emote", count = 1, name = "exclamation" },
            [2] = { action = "walk", direction = "west", speed = "slightly_fast", tiles = 5 },
            [3] = { action = "walk_in_place", count = 1, direction = "north", speed = "normal" },
          },
          op = "apply_movement",
          provenance = { offsets = { [1] = 1686 }, opcodes = { [1] = 94 } },
        },
        [3] = { op = "goto", provenance = { offsets = { [1] = 1694 }, opcodes = { [1] = 22 } }, target = "_06D4" },
        [4] = { name = "_06A4", op = "label" },
        [5] = {
          condition = { condition = "compare", left = { id = "VAR_BASE", value = "var" }, operator = "ne", right = 5 },
          op = "goto_if",
          provenance = { offsets = { [1] = 1700, [2] = 1706 }, opcodes = { [1] = 17, [2] = 28 } },
          target = "_06BF",
        },
        [6] = {
          actor = { mapIndex = 2, ref = "actor" },
          movement = {
            [1] = { action = "emote", count = 1, name = "exclamation" },
            [2] = { action = "walk", direction = "west", speed = "slightly_fast", tiles = 4 },
            [3] = { action = "walk_in_place", count = 1, direction = "north", speed = "normal" },
          },
          op = "apply_movement",
          provenance = { offsets = { [1] = 1713 }, opcodes = { [1] = 94 } },
        },
        [7] = { op = "goto", provenance = { offsets = { [1] = 1721 }, opcodes = { [1] = 22 } }, target = "_06D4" },
        [8] = { name = "_06BF", op = "label" },
        [9] = {
          condition = { condition = "compare", left = { id = "VAR_BASE", value = "var" }, operator = "ne", right = 6 },
          op = "goto_if",
          provenance = { offsets = { [1] = 1727, [2] = 1733 }, opcodes = { [1] = 17, [2] = 28 } },
          target = "_06D4",
        },
        [10] = {
          actor = { mapIndex = 2, ref = "actor" },
          movement = {
            [1] = { action = "emote", count = 1, name = "exclamation" },
            [2] = { action = "walk", direction = "west", speed = "slightly_fast", tiles = 3 },
            [3] = { action = "walk_in_place", count = 1, direction = "north", speed = "normal" },
          },
          op = "apply_movement",
          provenance = { offsets = { [1] = 1740 }, opcodes = { [1] = 94 } },
        },
      },
      op = "if",
      provenance = { offsets = { [1] = 1646, [2] = 1652 }, opcodes = { [1] = 17, [2] = 28 } },
      yes = {
        [1] = {
          actor = { mapIndex = 2, ref = "actor" },
          movement = {
            [1] = { action = "emote", count = 1, name = "exclamation" },
            [2] = { action = "walk", direction = "west", speed = "slightly_fast", tiles = 6 },
            [3] = { action = "walk_in_place", count = 1, direction = "north", speed = "normal" },
          },
          op = "apply_movement",
          provenance = { offsets = { [1] = 1659 }, opcodes = { [1] = 94 } },
        },
        [2] = { op = "goto", provenance = { offsets = { [1] = 1667 }, opcodes = { [1] = 22 } }, target = "_06D4" },
      },
    },
    { name = "_06D4", op = "label" },
    { op = "wait_movement", provenance = { offsets = { [1] = 1748 }, opcodes = { [1] = 95 } } },
    {
      op = "buffer_text",
      provenance = { offsets = { [1] = 1750 }, opcodes = { [1] = 190 } },
      slot = 0,
      value = { text = "player_name" },
    },
    {
      message = { female = "msg.hgss.0543.00020", male = "msg.hgss.0543.00019", text = "gendered_message" },
      op = "message",
      provenance = { offsets = { [1] = 1753 }, opcodes = { [1] = 132 } },
      waitForPrint = true,
    },
    {
      op = "set_var",
      provenance = { offsets = { [1] = 1757 }, opcodes = { [1] = 41 } },
      value = 17,
      variable = { id = "VAR_SPECIAL_x8004", value = "var" },
    },
    {
      op = "set_var",
      provenance = { offsets = { [1] = 1763 }, opcodes = { [1] = 41 } },
      value = 5,
      variable = { id = "VAR_SPECIAL_x8005", value = "var" },
    },
    {
      message = "msg.project.placeholder",
      op = "say",
      provenance = { offsets = { [1] = 1769 }, opcodes = { [1] = 127 } },
    },
    {
      condition = {
        condition = "compare",
        left = { id = "VAR_SPECIAL_RESULT", value = "var" },
        operator = "eq",
        right = 0,
      },
      no = {},
      op = "if",
      provenance = { offsets = { [1] = 1777, [2] = 1783 }, opcodes = { [1] = 17, [2] = 28 } },
      yes = { [1] = { label = "_0805", op = "goto_script", script = "vanilla.hgss.scr_seq.0843.script_001" } },
    },
    {
      op = "set_var",
      provenance = { offsets = { [1] = 1790 }, opcodes = { [1] = 41 } },
      value = 17,
      variable = { id = "VAR_SPECIAL_x8004", value = "var" },
    },
    {
      op = "set_var",
      provenance = { offsets = { [1] = 1796 }, opcodes = { [1] = 41 } },
      value = 5,
      variable = { id = "VAR_SPECIAL_x8005", value = "var" },
    },
    {
      message = "msg.project.placeholder",
      op = "say",
      provenance = { offsets = { [1] = 1802 }, opcodes = { [1] = 20 } },
    },
    { erase = true, op = "close_message", provenance = { offsets = { [1] = 1806 }, opcodes = { [1] = 53 } } },
    {
      op = "set_var",
      provenance = { offsets = { [1] = 1808 }, opcodes = { [1] = 41 } },
      value = 2,
      variable = { id = "VAR_SCENE_ELMS_LAB", value = "var" },
    },
    {
      message = "msg.hgss.0543.00021",
      op = "message",
      provenance = { offsets = { [1] = 1814 }, opcodes = { [1] = 45 } },
      waitForPrint = true,
    },
    { erase = true, op = "close_message", provenance = { offsets = { [1] = 1817 }, opcodes = { [1] = 53 } } },
    {
      condition = { condition = "compare", left = { id = "VAR_BASE", value = "var" }, operator = "eq", right = 3 },
      no = {
        [1] = {
          condition = { condition = "compare", left = { id = "VAR_BASE", value = "var" }, operator = "ne", right = 4 },
          op = "goto_if",
          provenance = { offsets = { [1] = 1846, [2] = 1852 }, opcodes = { [1] = 17, [2] = 28 } },
          target = "_0751",
        },
        [2] = {
          actor = { mapIndex = 2, ref = "actor" },
          movement = {
            [1] = { action = "walk", direction = "east", speed = "slightly_fast", tiles = 5 },
            [2] = { action = "walk_in_place", count = 1, direction = "west", speed = "normal" },
          },
          op = "apply_movement",
          provenance = { offsets = { [1] = 1859 }, opcodes = { [1] = 94 } },
        },
        [3] = { op = "goto", provenance = { offsets = { [1] = 1867 }, opcodes = { [1] = 22 } }, target = "_0781" },
        [4] = { name = "_0751", op = "label" },
        [5] = {
          condition = { condition = "compare", left = { id = "VAR_BASE", value = "var" }, operator = "ne", right = 5 },
          op = "goto_if",
          provenance = { offsets = { [1] = 1873, [2] = 1879 }, opcodes = { [1] = 17, [2] = 28 } },
          target = "_076C",
        },
        [6] = {
          actor = { mapIndex = 2, ref = "actor" },
          movement = {
            [1] = { action = "walk", direction = "east", speed = "slightly_fast", tiles = 4 },
            [2] = { action = "walk_in_place", count = 1, direction = "west", speed = "normal" },
          },
          op = "apply_movement",
          provenance = { offsets = { [1] = 1886 }, opcodes = { [1] = 94 } },
        },
        [7] = { op = "goto", provenance = { offsets = { [1] = 1894 }, opcodes = { [1] = 22 } }, target = "_0781" },
        [8] = { name = "_076C", op = "label" },
        [9] = {
          condition = { condition = "compare", left = { id = "VAR_BASE", value = "var" }, operator = "ne", right = 6 },
          op = "goto_if",
          provenance = { offsets = { [1] = 1900, [2] = 1906 }, opcodes = { [1] = 17, [2] = 28 } },
          target = "_0781",
        },
        [10] = {
          actor = { mapIndex = 2, ref = "actor" },
          movement = {
            [1] = { action = "walk", direction = "east", speed = "slightly_fast", tiles = 3 },
            [2] = { action = "walk_in_place", count = 1, direction = "west", speed = "normal" },
          },
          op = "apply_movement",
          provenance = { offsets = { [1] = 1913 }, opcodes = { [1] = 94 } },
        },
      },
      op = "if",
      provenance = { offsets = { [1] = 1819, [2] = 1825 }, opcodes = { [1] = 17, [2] = 28 } },
      yes = {
        [1] = {
          actor = { mapIndex = 2, ref = "actor" },
          movement = {
            [1] = { action = "walk", direction = "east", speed = "slightly_fast", tiles = 6 },
            [2] = { action = "walk_in_place", count = 1, direction = "west", speed = "normal" },
          },
          op = "apply_movement",
          provenance = { offsets = { [1] = 1832 }, opcodes = { [1] = 94 } },
        },
        [2] = { op = "goto", provenance = { offsets = { [1] = 1840 }, opcodes = { [1] = 22 } }, target = "_0781" },
      },
    },
    { name = "_0781", op = "label" },
    { op = "wait_movement", provenance = { offsets = { [1] = 1921 }, opcodes = { [1] = 95 } } },
    { op = "release_all", provenance = { offsets = { [1] = 1923 }, opcodes = { [1] = 97 } } },
    { op = "yield_tick" },
    { op = "stop", provenance = { offsets = { [1] = 1925 }, opcodes = { [1] = 2 } } },
  },
})
