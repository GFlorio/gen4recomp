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
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 1636 }, opcodes = { 609 } } }),
    S.lockAll(),
    S.getPlayerCoords({
      provenance = { offsets = { 1640 }, opcodes = { 105 } },
      x = S.var("VAR_BASE"),
      z = S.var("VAR_TEMP_x4001"),
    }),
    S.if_({
      condition = S.eq(S.var("VAR_BASE"), 3),
      yes = {
        S.applyMovement({
          actor = S.actorIndex(2),
          movement = {
            S.m.emote("exclamation", 1),
            S.m.walk("west", { speed = "slightly_fast", tiles = 6 }),
            S.m.walkInPlace("north", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 1659 }, opcodes = { 94 } },
        }),
      },
      no = {
        S.gotoIf(S.ne(S.var("VAR_BASE"), 4), "_06A4"),
        S.applyMovement({
          actor = S.actorIndex(2),
          movement = {
            S.m.emote("exclamation", 1),
            S.m.walk("west", { speed = "slightly_fast", tiles = 5 }),
            S.m.walkInPlace("north", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 1686 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_06D4" }),
        S.label("_06A4"),
        S.gotoIf(S.ne(S.var("VAR_BASE"), 5), "_06BF"),
        S.applyMovement({
          actor = S.actorIndex(2),
          movement = {
            S.m.emote("exclamation", 1),
            S.m.walk("west", { speed = "slightly_fast", tiles = 4 }),
            S.m.walkInPlace("north", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 1713 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_06D4" }),
        S.label("_06BF"),
        S.gotoIf(S.ne(S.var("VAR_BASE"), 6), "_06D4"),
        S.applyMovement({
          actor = S.actorIndex(2),
          movement = {
            S.m.emote("exclamation", 1),
            S.m.walk("west", { speed = "slightly_fast", tiles = 3 }),
            S.m.walkInPlace("north", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 1740 }, opcodes = { 94 } },
        }),
      },
    }),
    S.label("_06D4"),
    S.waitMovement(),
    S.bufferText({ provenance = { offsets = { 1750 }, opcodes = { 190 } }, slot = 0, value = { text = "player_name" } }),
    S.message({
      message = S.gendered("msg.hgss.0543.00019", "msg.hgss.0543.00020"),
      provenance = { offsets = { 1753 }, opcodes = { 132 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.setVar({
      provenance = { offsets = { 1757 }, opcodes = { 41 } },
      value = 17,
      variable = S.var("VAR_SPECIAL_x8004"),
    }),
    S.setVar({
      provenance = { offsets = { 1763 }, opcodes = { 41 } },
      value = 5,
      variable = S.var("VAR_SPECIAL_x8005"),
    }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 1769 }, opcodes = { 127 } } }),
    S.if_({
      condition = S.eq(S.var("VAR_SPECIAL_RESULT"), 0),
      yes = {
        S.gotoScript("vanilla.hgss.scr_seq.0843.script_001", { label = "_0805" }),
      },
      no = {},
    }),
    S.setVar({
      provenance = { offsets = { 1790 }, opcodes = { 41 } },
      value = 17,
      variable = S.var("VAR_SPECIAL_x8004"),
    }),
    S.setVar({
      provenance = { offsets = { 1796 }, opcodes = { 41 } },
      value = 5,
      variable = S.var("VAR_SPECIAL_x8005"),
    }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 1802 }, opcodes = { 20 } } }),
    S.closeMessage({ erase = true, provenance = { offsets = { 1806 }, opcodes = { 53 } } }),
    S.setVar({
      provenance = { offsets = { 1808 }, opcodes = { 41 } },
      value = 2,
      variable = S.var("VAR_SCENE_ELMS_LAB"),
    }),
    S.message({
      message = "msg.hgss.0543.00021",
      provenance = { offsets = { 1814 }, opcodes = { 45 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 1817 }, opcodes = { 53 } } }),
    S.if_({
      condition = S.eq(S.var("VAR_BASE"), 3),
      yes = {
        S.applyMovement({
          actor = S.actorIndex(2),
          movement = {
            S.m.walk("east", { speed = "slightly_fast", tiles = 6 }),
            S.m.walkInPlace("west", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 1832 }, opcodes = { 94 } },
        }),
      },
      no = {
        S.gotoIf(S.ne(S.var("VAR_BASE"), 4), "_0751"),
        S.applyMovement({
          actor = S.actorIndex(2),
          movement = {
            S.m.walk("east", { speed = "slightly_fast", tiles = 5 }),
            S.m.walkInPlace("west", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 1859 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_0781" }),
        S.label("_0751"),
        S.gotoIf(S.ne(S.var("VAR_BASE"), 5), "_076C"),
        S.applyMovement({
          actor = S.actorIndex(2),
          movement = {
            S.m.walk("east", { speed = "slightly_fast", tiles = 4 }),
            S.m.walkInPlace("west", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 1886 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_0781" }),
        S.label("_076C"),
        S.gotoIf(S.ne(S.var("VAR_BASE"), 6), "_0781"),
        S.applyMovement({
          actor = S.actorIndex(2),
          movement = {
            S.m.walk("east", { speed = "slightly_fast", tiles = 3 }),
            S.m.walkInPlace("west", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 1913 }, opcodes = { 94 } },
        }),
      },
    }),
    S.label("_0781"),
    S.waitMovement(),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
  },
})
