-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands replaced by a visible
-- placeholder dialogue. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "vanilla.hgss.scr_seq.0843.script_011",
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
      scriptIndex = 11,
    },
    coverage = { complete = false, unsupportedCount = 1 },
  },
  steps = {
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 202 }, opcodes = { 609 } } }),
    S.lockAll(),
    S.gotoIf(S.flag("FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE"), "_0197"),
    S.getPlayerCoords({
      provenance = { offsets = { 217 }, opcodes = { 105 } },
      x = S.var("VAR_BASE"),
      z = S.var("VAR_TEMP_x4001"),
    }),
    S.if_({
      condition = S.eq(S.var("VAR_BASE"), 3),
      yes = {
        S.applyMovement({
          actor = S.player(),
          movement = {
            S.m.walk("north", { speed = "normal", tiles = 2 }),
            S.m.walk("east", { speed = "normal", tiles = 1 }),
            S.m.walk("north", { speed = "normal", tiles = 1 }),
          },
          provenance = { offsets = { 236 }, opcodes = { 94 } },
        }),
      },
      no = {
        S.gotoIf(S.ne(S.var("VAR_BASE"), 4), "_0115"),
        S.applyMovement({
          actor = S.player(),
          movement = { S.m.walk("north", { speed = "normal", tiles = 3 }) },
          provenance = { offsets = { 263 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_0145" }),
        S.label("_0115"),
        S.gotoIf(S.ne(S.var("VAR_BASE"), 5), "_0130"),
        S.applyMovement({
          actor = S.player(),
          movement = {
            S.m.walk("north", { speed = "normal", tiles = 2 }),
            S.m.walk("west", { speed = "normal", tiles = 1 }),
            S.m.walk("north", { speed = "normal", tiles = 1 }),
          },
          provenance = { offsets = { 290 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_0145" }),
        S.label("_0130"),
        S.gotoIf(S.ne(S.var("VAR_BASE"), 6), "_0145"),
        S.applyMovement({
          actor = S.player(),
          movement = {
            S.m.walk("north", { speed = "normal", tiles = 2 }),
            S.m.walk("west", { speed = "normal", tiles = 2 }),
            S.m.walk("north", { speed = "normal", tiles = 1 }),
          },
          provenance = { offsets = { 317 }, opcodes = { 94 } },
        }),
      },
    }),
    S.label("_0145"),
    S.waitMovement(),
    S.bufferText({ provenance = { offsets = { 327 }, opcodes = { 190 } }, slot = 0, value = { text = "player_name" } }),
    S.message({
      message = S.gendered("msg.hgss.0543.00000", "msg.hgss.0543.00001"),
      provenance = { offsets = { 330 }, opcodes = { 132 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 334 }, opcodes = { 53 } } }),
    S.applyMovement({
      actor = S.player(),
      movement = { S.m.face("east", 1) },
      provenance = { offsets = { 336 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.waitTicks({
      countdownVariable = S.var("VAR_SPECIAL_x8004"),
      provenance = { offsets = { 346 }, opcodes = { 3 } },
      ticks = 15,
    }),
    S.playSound({ provenance = { offsets = { 352 }, opcodes = { 73 } }, sound = "SEQ_SE_GS_PHONE0" }),
    S.applyMovement({
      actor = S.player(),
      movement = { S.m.emote("exclamation", 1), S.m.walk("north", { speed = "normal", tiles = 1 }), S.m.delay(16, 1) },
      provenance = { offsets = { 356 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.message({
      message = "msg.hgss.0543.00002",
      provenance = { offsets = { 366 }, opcodes = { 45 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.message({
      message = "msg.hgss.0543.00003",
      provenance = { offsets = { 369 }, opcodes = { 45 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 372 }, opcodes = { 53 } } }),
    S.applyMovement({
      actor = S.player(),
      movement = { S.m.walk("south", { speed = "normal", tiles = 1 }) },
      provenance = { offsets = { 374 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.message({
      message = "msg.hgss.0543.00004",
      provenance = { offsets = { 384 }, opcodes = { 45 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 387 }, opcodes = { 53 } } }),
    S.applyMovement({
      actor = S.player(),
      movement = { S.m.face("east", 1) },
      provenance = { offsets = { 389 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.setFlag({ flag = "FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE", provenance = { offsets = { 399 }, opcodes = { 30 } } }),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
    S.label("_0197"),
    S.applyMovement({
      actor = S.player(),
      movement = {
        S.m.face("south", 1),
        S.m.emote("exclamation", 1),
        S.m.walkInPlace("south", { speed = "normal", count = 2 }),
      },
      provenance = { offsets = { 407 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.message({
      message = "msg.hgss.0543.00006",
      provenance = { offsets = { 417 }, opcodes = { 45 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 420 }, opcodes = { 53 } } }),
    S.applyMovement({
      actor = S.player(),
      movement = { S.m.face("east", 1) },
      provenance = { offsets = { 422 }, opcodes = { 94 } },
    }),
    S.applyMovement({
      actor = S.player(),
      movement = { S.m.walk("north", { speed = "normal", tiles = 1 }) },
      provenance = { offsets = { 430 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
  },
})
