-- Generated override (script override system): the supported flow of the
-- translated script with unsupported commands replaced by a visible
-- placeholder dialogue. Regenerate, do not hand-edit.
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "vanilla.hgss.scr_seq.0842.script_011",
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
      scriptIndex = 11,
    },
    coverage = { complete = false, unsupportedCount = 9 },
  },
  steps = {
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4768 }, opcodes = { 609 } } }),
    S.lockAll(),
    S.gotoIf(S.eq(S.var("VAR_TEMP_x4007"), 2), "_144F"),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4785 }, opcodes = { 307 } } }),
    S.playSound({ provenance = { offsets = { 4802 }, opcodes = { 73 } }, sound = "SEQ_SE_DP_KAIDAN2" }),
    S.clearFlag({ flag = "FLAG_HIDE_NEW_BARK_MOM", provenance = { offsets = { 4806 }, opcodes = { 31 } } }),
    S.showObject({ actor = S.actorIndex(7), provenance = { offsets = { 4810 }, opcodes = { 100 } } }),
    S.waitSound({ provenance = { offsets = { 4814 }, opcodes = { 75 } }, sound = "SEQ_SE_DP_KAIDAN2" }),
    S.applyMovement({
      actor = S.actorIndex(7),
      movement = { S.m.walk("south", { speed = "normal", tiles = 1 }) },
      provenance = { offsets = { 4818 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.gotoIf(S.ne(S.var("VAR_TEMP_x4007"), 0), "_12F1"),
    S.bufferText({ provenance = { offsets = { 4841 }, opcodes = { 190 } }, slot = 0, value = { text = "player_name" } }),
    S.message({
      message = "msg.hgss.0542.00021",
      provenance = { offsets = { 4844 }, opcodes = { 45 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 4847 }, opcodes = { 53 } } }),
    S.label("_12F1"),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4849 }, opcodes = { 311 } } }),
    S.getPlayerCoords({
      provenance = { offsets = { 4858 }, opcodes = { 105 } },
      x = S.var("VAR_SPECIAL_x8004"),
      z = S.var("VAR_SPECIAL_x8005"),
    }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 4864 }, opcodes = { 602 } } }),
    S.if_({
      condition = S.eq(S.var("VAR_SPECIAL_x8005"), 398),
      yes = {
        S.applyMovement({
          actor = S.actorIndex(7),
          movement = {
            S.m.walk("south", { speed = "normal", tiles = 1 }),
            S.m.walkInPlace("east", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 4887 }, opcodes = { 94 } },
        }),
        S.applyMovement({
          actor = S.player(),
          movement = {
            S.m.walkInPlace("west", { speed = "normal", count = 1 }),
            S.m.walk("west", { speed = "normal", tiles = 4 }),
          },
          provenance = { offsets = { 4895 }, opcodes = { 94 } },
        }),
      },
      no = {
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 399), "_1350"),
        S.applyMovement({
          actor = S.actorIndex(7),
          movement = {
            S.m.walk("south", { speed = "normal", tiles = 2 }),
            S.m.walkInPlace("east", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 4922 }, opcodes = { 94 } },
        }),
        S.applyMovement({
          actor = S.player(),
          movement = {
            S.m.walkInPlace("west", { speed = "normal", count = 1 }),
            S.m.walk("west", { speed = "normal", tiles = 4 }),
          },
          provenance = { offsets = { 4930 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_13A6" }),
        S.label("_1350"),
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 400), "_1373"),
        S.applyMovement({
          actor = S.actorIndex(7),
          movement = {
            S.m.walk("south", { speed = "normal", tiles = 3 }),
            S.m.walkInPlace("east", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 4957 }, opcodes = { 94 } },
        }),
        S.applyMovement({
          actor = S.player(),
          movement = {
            S.m.walkInPlace("west", { speed = "normal", count = 1 }),
            S.m.walk("west", { speed = "normal", tiles = 4 }),
          },
          provenance = { offsets = { 4965 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_13A6" }),
        S.label("_1373"),
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 401), "_1396"),
        S.applyMovement({
          actor = S.actorIndex(7),
          movement = {
            S.m.walk("south", { speed = "normal", tiles = 3 }),
            S.m.walkInPlace("east", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 4992 }, opcodes = { 94 } },
        }),
        S.applyMovement({
          actor = S.player(),
          movement = {
            S.m.walk("west", { speed = "normal", tiles = 2 }),
            S.m.walk("north", { speed = "normal", tiles = 1 }),
            S.m.walk("west", { speed = "normal", tiles = 2 }),
          },
          provenance = { offsets = { 5000 }, opcodes = { 94 } },
        }),
        S.goto_({ target = "_13A6" }),
        S.label("_1396"),
        S.applyMovement({
          actor = S.actorIndex(7),
          movement = {
            S.m.walk("south", { speed = "normal", tiles = 3 }),
            S.m.walkInPlace("east", { speed = "normal", count = 1 }),
          },
          provenance = { offsets = { 5014 }, opcodes = { 94 } },
        }),
        S.applyMovement({
          actor = S.player(),
          movement = {
            S.m.walk("west", { speed = "normal", tiles = 2 }),
            S.m.walk("north", { speed = "normal", tiles = 2 }),
            S.m.walk("west", { speed = "normal", tiles = 2 }),
          },
          provenance = { offsets = { 5022 }, opcodes = { 94 } },
        }),
      },
    }),
    S.label("_13A6"),
    S.waitMovement(),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5032 }, opcodes = { 603 } } }),
    S.if_({
      condition = S.eq(S.var("VAR_TEMP_x4007"), 0),
      yes = {
        S.message({
          message = "msg.hgss.0542.00022",
          provenance = { offsets = { 5055 }, opcodes = { 45 } },
          style = "npc",
          waitForPrint = true,
        }),
      },
      no = {
        S.message({
          message = "msg.hgss.0542.00023",
          provenance = { offsets = { 5064 }, opcodes = { 45 } },
          style = "npc",
          waitForPrint = true,
        }),
      },
    }),
    S.label("_13CB"),
    S.closeMessage({ erase = true, provenance = { offsets = { 5067 }, opcodes = { 53 } } }),
    S.if_({
      condition = S.eq(S.var("VAR_SPECIAL_x8005"), 398),
      yes = {
        S.applyMovement({
          actor = S.actorIndex(7),
          movement = { S.m.walk("north", { speed = "normal", tiles = 1 }) },
          provenance = { offsets = { 5082 }, opcodes = { 94 } },
        }),
        S.waitMovement(),
      },
      no = {
        S.gotoIf(S.ne(S.var("VAR_SPECIAL_x8005"), 399), "_1407"),
        S.applyMovement({
          actor = S.actorIndex(7),
          movement = { S.m.walk("north", { speed = "normal", tiles = 2 }) },
          provenance = { offsets = { 5111 }, opcodes = { 94 } },
        }),
        S.waitMovement(),
        S.goto_({ target = "_1411" }),
        S.label("_1407"),
        S.applyMovement({
          actor = S.actorIndex(7),
          movement = { S.m.walk("north", { speed = "normal", tiles = 3 }) },
          provenance = { offsets = { 5127 }, opcodes = { 94 } },
        }),
        S.waitMovement(),
      },
    }),
    S.label("_1411"),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5137 }, opcodes = { 307 } } }),
    S.applyMovement({
      actor = S.actorIndex(7),
      movement = { S.m.walk("north", { speed = "normal", tiles = 1 }) },
      provenance = { offsets = { 5154 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.setFlag({ flag = "FLAG_HIDE_NEW_BARK_MOM", provenance = { offsets = { 5164 }, opcodes = { 30 } } }),
    S.playSound({ provenance = { offsets = { 5168 }, opcodes = { 73 } }, sound = "SEQ_SE_DP_KAIDAN2" }),
    S.hideObject({ actor = S.actorIndex(7), provenance = { offsets = { 5172 }, opcodes = { 101 } } }),
    S.waitSound({ provenance = { offsets = { 5176 }, opcodes = { 75 } }, sound = "SEQ_SE_DP_KAIDAN2" }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5180 }, opcodes = { 311 } } }),
    S.addVar({ amount = 1, provenance = { offsets = { 5189 }, opcodes = { 39 } }, variable = S.var("VAR_TEMP_x4007") }),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
    S.label("_144F"),
    S.message({
      message = "msg.hgss.0542.00024",
      provenance = { offsets = { 5199 }, opcodes = { 45 } },
      style = "npc",
      waitForPrint = true,
    }),
    S.closeMessage({ erase = true, provenance = { offsets = { 5202 }, opcodes = { 53 } } }),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5204 }, opcodes = { 602 } } }),
    S.applyMovement({
      actor = S.player(),
      movement = { S.m.walk("west", { speed = "normal", tiles = 1 }) },
      provenance = { offsets = { 5214 }, opcodes = { 94 } },
    }),
    S.waitMovement(),
    S.say({ message = "msg.project.placeholder", provenance = { offsets = { 5224 }, opcodes = { 603 } } }),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
  },
})
