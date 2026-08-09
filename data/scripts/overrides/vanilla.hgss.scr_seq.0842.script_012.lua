-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands replaced by a visible
-- placeholder dialogue. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "vanilla.hgss.scr_seq.0842.script_012",
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
      scriptIndex = 12,
    },
    coverage = { complete = false, unsupportedCount = 3 },
  },
  steps = {
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5392 }, opcodes = { 609 } } }),
    S.lockAll(),
    S.applyMovement({
      actor = S.actorIndex(8),
      movement = { S.m.face("east", 1), S.m.emote("exclamation", 1) },
      provenance = { offsets = { 5396 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.bufferText({ provenance = { offsets = { 5406 }, opcodes = { 190 } }, slot = 0, value = { text = "player_name" } }),
    S.message({
      message = S.gendered("msg.hgss.0542.00027", "msg.hgss.0542.00028"),
      provenance = { offsets = { 5409 }, opcodes = { 132 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 5413 }, opcodes = { 53 } } }),
    S.getPlayerCoords({
      provenance = { offsets = { 5415 }, opcodes = { 105 } },
      x = S.var("VAR_SPECIAL_x8004"),
      z = S.var("VAR_SPECIAL_x8005"),
    }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5421 }, opcodes = { 602 } } }),
    S.if_({
      condition = S.eq(S.var("VAR_SPECIAL_x8005"), 398),
      yes = {
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walkInPlace("east", { speed = "normal", count = 1 }) },
          provenance = { offsets = { 5444 }, opcodes = { 94 } },
        }),
      },
      no = {
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 399), "_156D"),
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walkInPlace("east", { speed = "normal", count = 1 }) },
          provenance = { offsets = { 5471 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_15AB" }),
        S.label("_156D"),
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 399), "_1588"),
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walk("east", { speed = "normal", tiles = 1 }) },
          provenance = { offsets = { 5498 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_15AB" }),
        S.label("_1588"),
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 399), "_15A3"),
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walkInPlace("east", { speed = "normal", count = 1 }) },
          provenance = { offsets = { 5525 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_15AB" }),
        S.label("_15A3"),
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walkInPlace("east", { speed = "normal", count = 1 }) },
          provenance = { offsets = { 5539 }, opcodes = { 94 } },
        }),
      },
    }),
    S.label("_15AB"),
    S.applyMovement({
      actor = S.player(),
      movement = { S.m.walk("west", { speed = "normal", tiles = 2 }) },
      provenance = { offsets = { 5547 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5557 }, opcodes = { 603 } } }),
    S.bufferText({ provenance = { offsets = { 5567 }, opcodes = { 190 } }, slot = 0, value = { text = "player_name" } }),
    S.message({
      message = S.gendered("msg.hgss.0542.00029", "msg.hgss.0542.00030"),
      provenance = { offsets = { 5570 }, opcodes = { 132 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 5574 }, opcodes = { 53 } } }),
    S.if_({
      condition = S.eq(S.var("VAR_SPECIAL_x8005"), 398),
      yes = {
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walkInPlace("west", { speed = "normal", count = 1 }) },
          provenance = { offsets = { 5589 }, opcodes = { 94 } },
        }),
      },
      no = {
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 399), "_15FE"),
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walkInPlace("west", { speed = "normal", count = 1 }) },
          provenance = { offsets = { 5616 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_163C" }),
        S.label("_15FE"),
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 399), "_1619"),
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walkInPlace("west", { speed = "normal", count = 1 }) },
          provenance = { offsets = { 5643 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_163C" }),
        S.label("_1619"),
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 399), "_1634"),
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walkInPlace("west", { speed = "normal", count = 1 }) },
          provenance = { offsets = { 5670 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_163C" }),
        S.label("_1634"),
        S.applyMovement({
          actor = S.actorIndex(8),
          movement = { S.m.walkInPlace("west", { speed = "normal", count = 1 }) },
          provenance = { offsets = { 5684 }, opcodes = { 94 } },
        }),
      },
    }),
    S.label("_163C"),
    S.waitMovement(),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
  },
})
