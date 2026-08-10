-- Compiler and graph tests. They pin the internal graph contract: node IDs
-- (key/src/path forms), resolved control edges, the semantic revision hash,
-- load-time structural validation, warnings, immutability, and deterministic
-- inspection. Every supported authoring construct compiles to a deterministic
-- graph.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local S = require("gen4.script")
local Compiler = require("libs.engine.src.script.Compiler")
local Graph = require("libs.engine.src.script.Graph")
local Sha256 = require("libs.engine.src.script.Sha256")

local T = {}

local function compile(script, opts)
  local graph, err = Compiler.compile(script, opts)
  if not graph then
    error("compile failed: " .. tostring(err))
  end
  return graph
end

---@param code string
---@param script any
---@param opts table|nil
---@return Errors.Error
local function compileError(code, script, opts)
  local graph, err = Compiler.compile(script, opts)
  Assert.isNil(graph)
  Assert.isTrue(Errors.is(err), "expected Errors object, got: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
  return err
end

local function signScript()
  return S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = {
      S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
      S.lockAll(),
      S.say({ message = "msg.hgss.0543.00097" }),
      S.releaseAll(),
    },
  })
end

local function womanScript()
  return S.script({
    api = 1,
    id = "new_bark.npc.woman_1",
    steps = {
      S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
      S.lockAll(),
      S.facePlayer({ actor = "self" }),
      S.if_({
        condition = S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 0),
        yes = { S.say({ message = "msg.hgss.0542.00009" }) },
        no = {
          S.if_({
            condition = S.any({
              S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 1),
              S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 2),
            }),
            yes = { S.say({ message = "msg.hgss.0542.00005" }) },
            no = {
              S.if_({
                condition = S.eq(S.var("VAR_SCENE_NEW_BARK_WEST_EXIT"), 1),
                yes = { S.say({ message = "msg.hgss.0542.00000" }) },
                no = {
                  S.bufferText({ slot = 0, value = S.playerName() }),
                  S.say({ message = S.gendered("msg.hgss.0542.00006", "msg.hgss.0542.00007") }),
                },
              }),
            },
          }),
        },
      }),
      S.releaseAll(),
    },
  })
end

-- Every-op sweep: one step per canonical operation plus a label pair for
-- local control targets. Compiles with wrapper permission for `next`.
local function allOpsScript()
  local steps = {
    S.noop(),
    S.waitTicks({ ticks = 2 }),
    S.if_({ condition = S.flag("FLAG_F"), yes = { S.next() }, no = { S.noop() } }),
    S.switch({ value = S.var("VAR_V"), cases = { [0] = { S.noop() } }, default = { S.noop(), S.stop() } }),
    S.call({ target = "sub" }),
    S.callCommon({ target = "common.example" }),
    S.compare({ left = 1, right = 2 }),
    S.setFlag({ flag = "FLAG_A" }),
    S.clearFlag({ flag = "FLAG_A" }),
    S.setVar({ variable = "VAR_A", value = 1 }),
    S.copyVar({ destination = "VAR_B", source = "VAR_A" }),
    S.addVar({ variable = "VAR_A", amount = 1 }),
    S.subVar({ variable = "VAR_A", amount = 1 }),
    S.setLocal({ name = "route", value = "intro" }),
    S.copyLocal({ destination = "r2", source = "route" }),
    S.addLocal({ name = "counter", amount = 1 }),
    S.subLocal({ name = "counter", amount = 1 }),
    S.say({ message = "msg.x" }),
    S.openMessage(),
    S.message({ message = "msg.y", waitForPrint = true }),
    S.waitInput(),
    S.waitInputOrTicks({ ticks = 3 }),
    S.closeMessage(),
    S.holdMessage(),
    S.askYesNo({ result = S.local_("yn") }),
    S.bufferText({ slot = 0, value = S.playerName() }),
    S.showWaitingIcon(),
    S.hideWaitingIcon(),
    S.resolveCommonMessageBank({ script = "msg.x", bankResult = S.local_("bank"), memberResult = S.local_("member") }),
    S.lockPlayer(),
    S.releasePlayer(),
    S.lockAll(),
    S.releaseAll(),
    S.lockActor({ actor = "elm" }),
    S.releaseActor({ actor = "elm" }),
    S.facePlayer({}),
    S.face({ actor = "elm", direction = "south" }),
    S.showObject({ actor = "elm" }),
    S.hideObject({ actor = "elm" }),
    S.setObjectPosition({ actor = "elm", fieldX = 4, fieldZ = 5 }),
    S.setObjectFacing({ actor = "elm", direction = "north" }),
    S.setObjectMovementType({ actor = "elm", movementType = "stationary" }),
    S.getPlayerCoords({ x = S.local_("px"), z = S.local_("pz") }),
    S.getObjectCoords({ actor = "elm", x = S.local_("ex"), z = S.local_("ez") }),
    S.getPlayerFacing({ result = S.local_("pf") }),
    S.applyMovement({ actor = "elm", movement = { S.m.walk({ direction = "south", speed = "normal", tiles = 2 }) } }),
    S.waitMovement(),
    S.move({ actor = "elm", movement = { S.m.face({ direction = "north" }) } }),
    S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.stopSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.waitSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.playCry({ species = S.var("species"), form = 0 }),
    S.waitCry(),
    S.playFanfare({ fanfare = "SEQ_ME_POKEGET" }),
    S.waitFanfare(),
    S.playMusic({ music = "SEQ_GS_NEW_BARK" }),
    S.stopMusic({ music = "SEQ_GS_NEW_BARK" }),
    S.resetMusic(),
    S.temporaryMusic({ music = "SEQ_GS_EVENT" }),
    S.fadeMusicOut({ target = 0, durationTicks = 30 }),
    S.fadeMusicIn({ durationTicks = 30 }),
    S.fadeScreen({ kind = 6, speed = 1, direction = "out", color = "black" }),
    S.waitFade(),
    S.warp({ map = "MAP_NEW_BARK", warp = 0, fieldX = 684, fieldZ = 393, facing = "south" }),
    S.setSpawn({ spawn = "SPAWN_NEW_BARK" }),
    S.shakeCamera({ amplitudeX = 2, amplitudeY = 0, intervalTicks = 2, count = 8 }),
    S.random({ maxExclusive = 10, result = S.local_("roll") }),
    S.lua({ module = "scripts.story.elm", fn = "chooseStarter", args = {}, result = S.local_("starter") }),
    S.unsupported({
      command = 0x017A,
      originalName = "ScrCmd_378",
      arguments = { 4, 0x800C },
      sourceOffset = 0x92,
      reason = "no semantic adapter",
    }),
    S.yieldTick(),
    S.gotoIf({ condition = S.flag("FLAG_F"), target = "sub" }),
    S.gotoCompared({ operator = "eq", target = "sub" }),
    S.goto_({ target = "sub" }),
    S.label({ name = "sub" }),
    S.callCompared({ operator = "ne", target = "sub2" }),
    S.label({ name = "sub2" }),
    S.return_({}),
  }
  return S.script({
    api = 1,
    id = "sweep.every_op",
    metadata = { generated = true },
    locals = {
      route = "string",
      r2 = "string",
      counter = "integer",
      yn = "bool",
      bank = "id",
      member = "id",
      px = "integer",
      pz = "integer",
      ex = "integer",
      ez = "integer",
      pf = "id",
      roll = "integer",
      starter = "serializable",
    },
    steps = steps,
  })
end

-- --- Sha256 (FIPS 180-4 vectors) ---

function T.sha256_standard_vectors()
  Assert.equal(Sha256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  Assert.equal(Sha256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  Assert.equal(
    Sha256.hex("The quick brown fox jumps over the lazy dog"),
    "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
  )
end

function T.sha256_multi_block_input()
  Assert.equal(Sha256.hex(string.rep("a", 100000)), "6d1cf22d7cc09b085dfc25ee1a1f3ae0265804c607bc2074ad253bcc82fd81ee")
end

-- --- Basic compilation ---

function T.flat_sequence_compiles_to_linear_graph()
  local graph = compile(signScript())
  Assert.equal(graph.graphSchema, "g4-script-graph-v1")
  Assert.equal(graph.api, 1)
  Assert.equal(graph.scriptId, "new_bark.lab_sign")
  Assert.equal(graph.entry, "path:steps/0")
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "play_sound",
    sound = "SEQ_SE_DP_SELECT",
    next = "path:steps/1",
  })
  Assert.deepEqual(graph.nodes["path:steps/1"], {
    op = "lock_all",
    next = "path:steps/2",
  })
  Assert.deepEqual(graph.nodes["path:steps/2"], {
    op = "say",
    message = "msg.hgss.0543.00097",
    style = "npc",
    wait = "button",
    close = true,
    timingProfile = "hgss",
    bindings = {},
    next = "path:steps/3",
  })
  Assert.deepEqual(graph.nodes["path:steps/3"], { op = "release_all" })
end

function T.nested_if_compiles_branches()
  local graph = compile(womanScript())
  Assert.equal(graph.entry, "path:steps/0")
  Assert.deepEqual(graph.nodes["path:steps/3"], {
    op = "if",
    condition = {
      condition = "compare",
      operator = "eq",
      left = { value = "var", id = "VAR_SCENE_NEW_BARK_TOWN_OW" },
      right = 0,
    },
    yes = "path:steps/3/yes/0",
    no = "path:steps/3/no/0",
  })
  Assert.deepEqual(graph.nodes["path:steps/3/no/0/no/0"], {
    op = "if",
    condition = {
      condition = "compare",
      operator = "eq",
      left = { value = "var", id = "VAR_SCENE_NEW_BARK_WEST_EXIT" },
      right = 1,
    },
    yes = "path:steps/3/no/0/no/0/yes/0",
    no = "path:steps/3/no/0/no/0/no/0",
  })
  -- Every branch tail continues at the step after the outermost if.
  Assert.equal(graph.nodes["path:steps/3/yes/0"].next, "path:steps/4")
  Assert.equal(graph.nodes["path:steps/3/no/0/no/0/no/1"].next, "path:steps/4")
  Assert.equal(graph.nodes["path:steps/4"].op, "release_all")
end

function T.switch_compiles_cases_and_default()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.switch({
        value = S.var("VAR_V"),
        cases = { [0] = { S.noop() }, [2] = { S.noop() } },
        default = { S.noop() },
      }),
      S.setVar({ variable = "VAR_A", value = 9 }),
    },
  }))
  local node = graph.nodes["path:steps/0"]
  Assert.equal(node.op, "switch")
  Assert.equal(node.value.value, "var")
  Assert.equal(node.cases[0], "path:steps/0/0/0")
  Assert.equal(node.cases[2], "path:steps/0/2/0")
  Assert.equal(node.default, "path:steps/0/default/0")
  Assert.equal(graph.nodes["path:steps/0/0/0"].next, "path:steps/1")
  Assert.equal(graph.nodes["path:steps/0/default/0"].next, "path:steps/1")
end

function T.if_without_else_falls_through()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "if", condition = S.flag("FLAG_F"), yes = { S.noop() } },
      S.setVar({ variable = "VAR_A", value = 1 }),
    },
  }))
  local node = graph.nodes["path:steps/0"]
  Assert.equal(node.yes, "path:steps/0/yes/0")
  Assert.equal(node.no, "path:steps/1")
end

-- --- Local calls and labels ---

function T.call_to_local_label_resolves_target_node()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.call({ target = "sub" }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.label({ name = "sub" }),
      S.setFlag({ flag = "FLAG_X" }),
      S.return_({}),
    },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "call",
    target = "sub",
    args = {},
    targetNode = "path:steps/2",
    returnNode = "path:steps/1",
  })
  Assert.deepEqual(graph.nodes["path:steps/2"], {
    op = "label",
    name = "sub",
    next = "path:steps/3",
  })
  Assert.deepEqual(graph.nodes["path:steps/4"], { op = "return" })
end

function T.call_to_external_target_stays_a_script_id()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = { S.call({ target = "common.give_item_verbose", args = { item = "ITEM_POTION", quantity = 1 } }) },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "call",
    target = "common.give_item_verbose",
    args = { item = "ITEM_POTION", quantity = 1 },
  })
end

function T.goto_and_goto_if_resolve_label_targets()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.goto_({ target = "end" }),
      S.gotoIf({ condition = S.flag("FLAG_F"), target = "end" }),
      S.label({ name = "end" }),
      S.stop(),
    },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "goto",
    target = "end",
    targetNode = "path:steps/2",
  })
  Assert.deepEqual(graph.nodes["path:steps/1"], {
    op = "goto_if",
    condition = { condition = "flag", id = "FLAG_F", expected = true },
    target = "end",
    targetNode = "path:steps/2",
    next = "path:steps/2",
  })
end

function T.missing_goto_label_raises()
  compileError(
    "SCRIPT_LABEL_MISSING",
    S.script({
      api = 1,
      id = "x",
      steps = { S.goto_({ target = "nowhere" }) },
    })
  )
  compileError(
    "SCRIPT_LABEL_MISSING",
    S.script({
      api = 1,
      id = "x",
      steps = { S.gotoIf({ condition = S.flag("FLAG_F"), target = "nowhere" }) },
    })
  )
end

function T.duplicate_label_raises()
  local err = compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = {
        S.label({ name = "a" }),
        S.goto_({ target = "skip" }),
        S.label({ name = "a" }),
        S.label({ name = "skip" }),
        S.stop(),
      },
    })
  )
  Assert.equal(err.context.label, "a")
end

function T.wrapper_next_requires_registration()
  compileError(
    "SCRIPT_WRAPPER_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = { S.next() },
    })
  )
  local graph = compile(
    S.script({
      api = 1,
      id = "x",
      steps = { S.next() },
    }),
    { allowNext = true }
  )
  Assert.isTrue(graph.usesNext)
  Assert.deepEqual(graph.nodes["path:steps/0"], { op = "next" })
end

-- --- Node IDs ---

function T.author_key_overrides_node_id()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "set_var", variable = "VAR_A", value = 1, key = "after_intro" },
      S.stop(),
    },
  }))
  Assert.equal(graph.nodes["key:after_intro"].op, "set_var")
  Assert.equal(graph.entry, "key:after_intro")
  Assert.equal(graph.nodes["key:after_intro"].next, "path:steps/1")
end

function T.duplicate_key_raises()
  compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = {
        { op = "noop", key = "dup" },
        { op = "noop", key = "dup" },
      },
    })
  )
end

function T.generated_node_ids_use_source_provenance()
  local graph = compile(S.script({
    api = 1,
    id = "elms_lab.generated.script_000",
    metadata = {
      generated = true,
      source = {
        repository = "pret/pokeheartgold",
        commit = "dfdbbdf3273545ca35456d69bcb0ee3403f76450",
        path = "files/fielddata/script/scr_seq/scr_seq_0843_T20R0101.s",
        game = "heartgold",
        archive = "scr_seq",
        member = 843,
        scriptIndex = 9,
        sourceHash = "h",
      },
    },
    steps = {
      { op = "play_sound", sound = "SEQ_SE_DP_SELECT", provenance = { offsets = { 0x00 }, opcodes = { 73 } } },
      {
        op = "say",
        message = "msg.hgss.0543.00097",
        provenance = { offsets = { 0x04, 0x08, 0x0C }, opcodes = { 45, 50, 53 } },
      },
    },
  }))
  Assert.equal(graph.entry, "src:0843:009:0000")
  Assert.equal(graph.nodes["src:0843:009:0000"].sound, "SEQ_SE_DP_SELECT")
  Assert.equal(graph.nodes["src:0843:009:0004/say"].op, "say")
  Assert.deepEqual(
    graph.nodes["src:0843:009:0004/say"].source,
    { offsets = { 0x04, 0x08, 0x0C }, opcodes = { 45, 50, 53 } }
  )
end

function T.step_provenance_without_member_metadata_raises()
  compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = {
        { op = "play_sound", sound = "SEQ_SE_DP_SELECT", provenance = { offsets = { 0x00 }, opcodes = { 73 } } },
      },
    })
  )
end

-- --- Normalization ---

function T.direct_and_constructor_forms_compile_identically()
  local constructorForm = S.script({
    api = 1,
    id = "x",
    steps = { S.waitInput() },
  })
  local directForm = {
    kind = "field_script",
    api = 1,
    id = "x",
    steps = { { op = "wait_input" } },
  }
  local g1 = compile(constructorForm)
  local g2 = compile(directForm)
  Assert.deepEqual(g1.nodes, g2.nodes)
  Assert.equal(g1.revision, g2.revision)
end

function T.defaults_are_normalized_into_nodes()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = { { op = "wait_input" } },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "wait_input",
    buttons = { "a", "b" },
    allowDpad = false,
    turnPlayerOnDpad = false,
  })
end

function T.string_actors_normalize_to_references()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "face_player", actor = "self" },
      { op = "face", actor = "elm", direction = "south" },
    },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"].actor, { ref = "actor", special = "self" })
  Assert.deepEqual(graph.nodes["path:steps/1"].actor, { ref = "actor", id = "elm" })
end

function T.condition_defaults_normalize()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "if", condition = S.flag("FLAG_F"), yes = { S.noop() } },
    },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"].condition, { condition = "flag", id = "FLAG_F", expected = true })
end

function T.condition_and_value_defaults_are_frozen_copies()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "if", condition = S.flag("FLAG_F"), yes = { S.noop() } },
    },
  }))
  local node = graph.nodes["path:steps/0"]
  local ok = pcall(function()
    node.condition.injected = true
  end)
  Assert.isFalse(ok, "nested condition must be frozen")
end

-- --- Revision hash ---

function T.compile_is_deterministic()
  local g1 = compile(signScript())
  local g2 = compile(signScript())
  Assert.equal(g1.revision, g2.revision)
  Assert.deepEqual(g1.nodes, g2.nodes)
  Assert.equal(#g1.revision, 64)
end

function T.provenance_only_edits_do_not_change_revision()
  local function generated(meta)
    return S.script({
      api = 1,
      id = "new_bark.lab_sign",
      metadata = meta,
      steps = {
        { op = "play_sound", sound = "SEQ_SE_DP_SELECT", provenance = { offsets = { 0x00 }, opcodes = { 73 } } },
        {
          op = "say",
          message = "msg.hgss.0543.00097",
          provenance = { offsets = { 0x04, 0x08, 0x0C }, opcodes = { 45, 50, 53 } },
        },
      },
    })
  end
  local base = generated({
    generated = true,
    source = {
      repository = "pret/pokeheartgold",
      commit = "dfdb",
      path = "files/fielddata/script/scr_seq/scr_seq_0843_T20R0101.s",
      game = "heartgold",
      archive = "scr_seq",
      member = 843,
      scriptIndex = 9,
      sourceHash = "h1",
    },
    coverage = { complete = true, unsupportedCount = 0 },
  })
  local edited = generated({
    generated = true,
    source = {
      repository = "pret/pokeheartgold",
      commit = "OTHER-COMMIT",
      path = "some/other/path.s",
      game = "heartgold",
      archive = "scr_seq",
      member = 843,
      scriptIndex = 9,
      sourceHash = "h2",
    },
    coverage = { complete = false, unsupportedCount = 1 },
  })
  local g1 = compile(base)
  local g2 = compile(edited)
  Assert.equal(g1.revision, g2.revision)
end

function T.semantic_edits_change_revision()
  local base = S.script({
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = "VAR_A", value = 1 }), S.setFlag({ flag = "FLAG_X" }) },
  })
  local g1 = compile(base)

  local value = S.script({
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = "VAR_A", value = 2 }), S.setFlag({ flag = "FLAG_X" }) },
  })
  Assert.isFalse(g1.revision == compile(value).revision, "operand change must change revision")

  local op = S.script({
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = "VAR_A", value = 1 }), S.clearFlag({ flag = "FLAG_X" }) },
  })
  Assert.isFalse(g1.revision == compile(op).revision, "op change must change revision")

  local added = S.script({
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = "VAR_A", value = 1 }), S.setFlag({ flag = "FLAG_X" }), S.noop() },
  })
  Assert.isFalse(g1.revision == compile(added).revision, "added step must change revision")

  local condition = S.script({
    api = 1,
    id = "x",
    steps = {
      S.if_({ condition = S.eq(S.var("VAR_A"), 1), yes = { S.setVar({ variable = "VAR_A", value = 1 }) } }),
      S.setFlag({ flag = "FLAG_X" }),
    },
  })
  local condition2 = S.script({
    api = 1,
    id = "x",
    steps = {
      S.if_({ condition = S.eq(S.var("VAR_A"), 2), yes = { S.setVar({ variable = "VAR_A", value = 1 }) } }),
      S.setFlag({ flag = "FLAG_X" }),
    },
  })
  Assert.isFalse(compile(condition).revision == compile(condition2).revision, "condition change must change revision")
end

function T.declared_params_and_locals_are_in_the_revision()
  local base = S.script({
    api = 1,
    id = "x",
    params = { professor = "actor_ref" },
    locals = { route = "string" },
    steps = { S.stop() },
  })
  local renamed = S.script({
    api = 1,
    id = "x",
    params = { professor = "actor_ref" },
    locals = { path_ = "string" },
    steps = { S.stop() },
  })
  Assert.isFalse(compile(base).revision == compile(renamed).revision, "declared local change must change revision")
end

-- --- Structural validation ---

function T.compile_propagates_validator_errors()
  compileError(
    "SCRIPT_UNKNOWN_OPERATION",
    S.script({
      api = 1,
      id = "x",
      steps = { { op = "teleport_to_kanto" } },
    })
  )
  compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = { S.stop() },
      metadata = { callback = function() end },
    })
  )
end

function T.recursive_call_cycle_without_blocking_edge_faults()
  local err = compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = {
        S.call({ target = "a" }),
        S.label({ name = "a" }),
        S.call({ target = "b" }),
        S.label({ name = "b" }),
        S.call({ target = "a" }),
      },
    })
  )
  table.sort(err.context.cycle)
  Assert.deepEqual(err.context.cycle, { "a", "b" })
end

function T.self_recursive_call_without_blocking_edge_faults()
  compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = {
        S.label({ name = "a" }),
        S.call({ target = "a" }),
      },
    })
  )
end

function T.recursive_call_cycle_with_blocking_edge_compiles()
  compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.call({ target = "a" }),
      S.label({ name = "a" }),
      S.waitTicks({ ticks = 2 }),
      S.call({ target = "b" }),
      S.label({ name = "b" }),
      S.waitTicks({ ticks = 2 }),
      S.call({ target = "a" }),
    },
  }))
  compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.label({ name = "a" }),
      S.stop(),
      S.call({ target = "a" }),
    },
  }))
end

function T.fallthrough_label_chain_cycle_is_detected()
  compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = {
        S.label({ name = "a" }),
        S.label({ name = "b" }),
        S.call({ target = "a" }),
      },
    })
  )
end

function T.call_before_label_is_not_a_cycle()
  compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.call({ target = "sub" }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.label({ name = "sub" }),
      S.setFlag({ flag = "FLAG_X" }),
      S.return_({}),
    },
  }))
end

function T.maximum_static_nesting_is_enforced()
  local current = { S.noop() }
  for _ = 1, 70 do
    current = { S.if_({ condition = S.flag("FLAG_F"), yes = current }) }
  end
  compileError("SCRIPT_SCHEMA_INVALID", S.script({ api = 1, id = "x", steps = current }))

  local shallow = { S.noop() }
  for _ = 1, 60 do
    shallow = { S.if_({ condition = S.flag("FLAG_F"), yes = shallow }) }
  end
  compile(S.script({ api = 1, id = "x", steps = shallow }))
end

-- --- Unsupported reachability ---

function T.reachable_unsupported_flags_the_graph()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.unsupported({
        command = 0x017A,
        originalName = "ScrCmd_378",
        arguments = { 4, 0x800C },
        sourceOffset = 0x92,
        reason = "no semantic adapter",
      }),
      S.setVar({ variable = "VAR_A", value = 1 }),
    },
  }))
  Assert.isTrue(graph.hasUnsupported)
  Assert.deepEqual(graph.unsupportedNodes, { "path:steps/0" })
end

function T.unreachable_unsupported_does_not_disable_the_graph()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.stop(),
      S.unsupported({ command = 1, originalName = "X", reason = "dead" }),
    },
  }))
  Assert.isFalse(graph.hasUnsupported)
end

function T.unsupported_behind_unconditional_jump_is_ignored()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.goto_({ target = "end" }),
      S.unsupported({ command = 1, originalName = "X", reason = "dead" }),
      S.label({ name = "end" }),
      S.stop(),
    },
  }))
  Assert.isFalse(graph.hasUnsupported)
end

-- --- Warnings ---

local function warningMessages(graph)
  local out = {}
  for _, w in ipairs(graph.warnings) do
    out[#out + 1] = w.nodeId .. ": " .. w.message
  end
  return out
end

local function countNodes(graph)
  local count = 0
  for _ in pairs(graph.nodes) do
    count = count + 1
  end
  return count
end

function T.empty_branches_warn()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "if", condition = S.flag("FLAG_F"), yes = {}, no = { S.noop() } },
      { op = "switch", value = S.var("VAR_V"), cases = { [0] = {} }, default = { S.noop() } },
    },
  }))
  local warnings = warningMessages(graph)
  Assert.isTrue(#warnings == 2, "expected 2 warnings, got: " .. #warnings)
  Assert.isTrue(warnings[1]:find("empty yes branch") ~= nil, warnings[1])
  Assert.isTrue(warnings[2]:find("empty switch case") ~= nil, warnings[2])
end

function T.unreachable_nodes_warn()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.stop(),
      S.setVar({ variable = "VAR_A", value = 1 }),
    },
  }))
  Assert.deepEqual(warningMessages(graph), { "path:steps/1: unreachable node" })
end

function T.handwritten_fallback_control_warns_but_generated_does_not()
  local function fallbackScript()
    return S.script({
      api = 1,
      id = "x",
      steps = {
        S.goto_({ target = "end" }),
        S.label({ name = "end" }),
        S.stop(),
      },
    })
  end
  local handwritten = compile(fallbackScript())
  Assert.deepEqual(warningMessages(handwritten), {
    "path:steps/0: handwritten script uses label/goto fallback",
    "path:steps/1: handwritten script uses label/goto fallback",
  })

  local generated = compile(S.script({
    api = 1,
    id = "x",
    metadata = { generated = true },
    steps = {
      S.goto_({ target = "end" }),
      S.label({ name = "end" }),
      S.stop(),
    },
  }))
  Assert.equal(#generated.warnings, 0)
end

function T.warnings_are_deterministically_ordered()
  local function script()
    return S.script({
      api = 1,
      id = "x",
      steps = {
        S.stop(),
        S.goto_({ target = "end" }),
        S.label({ name = "end" }),
      },
    })
  end
  local g1 = compile(script())
  local g2 = compile(script())
  Assert.deepEqual(g1.warnings, g2.warnings)
  Assert.equal(Graph.inspect(g1), Graph.inspect(g2))
end

-- --- Immutability and independence ---

function T.graph_is_immutable()
  local graph = compile(signScript())
  Assert.isFalse(pcall(function()
    graph.injected = true
  end))
  Assert.isFalse(pcall(function()
    graph.nodes["injected"] = {}
  end))
  Assert.isFalse(pcall(function()
    graph.nodes["path:steps/0"].injected = true
  end))
  Assert.isFalse(pcall(function()
    graph.nodes["path:steps/2"].bindings.injected = true
  end))
end

function T.graph_does_not_share_author_tables()
  local author = S.script({
    api = 1,
    id = "x",
    params = { professor = "actor_ref" },
    steps = {
      S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
      S.say({ message = "msg.x", bindings = { [0] = S.playerName() } }),
    },
  })
  local graph = compile(author)
  author.steps[1].sound = "SEQ_SE_DP_MUTATED"
  author.steps[2].bindings[0] = S.rivalName()
  author.params.professor = "string"
  Assert.equal(graph.nodes["path:steps/0"].sound, "SEQ_SE_DP_SELECT")
  Assert.deepEqual(graph.nodes["path:steps/1"].bindings[0], { text = "player_name" })
  Assert.equal(graph.params.professor, "actor_ref")
end

-- --- Graph inspection and the every-op sweep ---

function T.inspect_is_deterministic_and_identifying()
  local g1 = compile(signScript())
  local g2 = compile(signScript())
  Assert.equal(Graph.inspect(g1), Graph.inspect(g2))
  local other = compile(S.script({ api = 1, id = "y", steps = { S.stop() } }))
  Assert.isFalse(Graph.inspect(g1) == Graph.inspect(other))
  Assert.isTrue(Graph.inspect(g1):find('graphSchema = "g4-script-graph-v1"', 1, true) ~= nil)
  Assert.isTrue(Graph.inspect(g1):find(g1.revision) ~= nil)
end

function T.every_supported_operation_compiles_to_a_graph()
  local script = allOpsScript()
  local graph = compile(script, { allowNext = true })
  Assert.equal(countNodes(graph), #script.steps + 5)
  Assert.equal(graph.usesNext, true)
  Assert.equal(graph.hasUnsupported, true)
  Assert.equal(#graph.warnings, 0)
  Assert.equal(graph.entry, "path:steps/0")
  local revisit = compile(allOpsScript(), { allowNext = true })
  Assert.equal(graph.revision, revisit.revision)
end

function T.empty_script_compiles()
  local graph = compile(S.script({ api = 1, id = "x", steps = {} }))
  Assert.isNil(graph.entry)
  Assert.equal(next(graph.nodes), nil)
  Assert.equal(graph.hasUnsupported, false)
end

function T.graph_carries_declarations()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    params = { professor = "actor_ref" },
    locals = { route = "string" },
    steps = { S.stop() },
  }))
  Assert.deepEqual(graph.params, { professor = "actor_ref" })
  Assert.deepEqual(graph.locals, { route = "string" })
end

function T.reachable_nodes_follows_deterministic_order()
  local graph = compile(womanScript())
  local order = Graph.reachableNodes(graph)
  Assert.equal(order[1], graph.entry)
  local seen = {}
  for _, id in ipairs(order) do
    Assert.isNil(seen[id], "reachable order must not repeat nodes")
    seen[id] = true
  end
  Assert.equal(#order, countNodes(graph))
end

-- --- Per-call state isolation ---

-- Compiling script B between two compiles of script A must not leak A's
-- labels, warnings, nodes, used node ids, or wrapper flag into B, nor leave
-- any residue that changes a later A.
function T.compiler_calls_do_not_contaminate_one_another()
  local a = S.script({
    api = 1,
    id = "a",
    steps = {
      S.goto_({ target = "end" }),
      S.label({ name = "end" }),
      S.stop(),
      S.setVar({ variable = "VAR_A", value = 1 }),
    },
  })
  local function b()
    return S.script({
      api = 1,
      id = "b",
      metadata = { generated = true, source = { member = 843, scriptIndex = 9 } },
      steps = {
        { op = "noop", provenance = { offsets = { 0x00 }, opcodes = { 0 } } },
      },
    })
  end
  local g1 = compile(a)
  local gb1 = compile(b())
  local g2 = compile(a)
  local gb2 = compile(b())
  Assert.deepEqual(g1.nodes, g2.nodes)
  Assert.deepEqual(g1.warnings, g2.warnings)
  Assert.deepEqual(g1.labels, g2.labels)
  Assert.equal(g1.revision, g2.revision)
  -- B keeps its own node ids and carries none of A's labels or warnings.
  Assert.equal(gb1.entry, "src:0843:009:0000")
  Assert.equal(gb2.entry, "src:0843:009:0000")
  Assert.equal(next(gb1.labels), nil, "B must not inherit A's labels")
  Assert.equal(next(gb2.labels), nil, "B must not inherit A's labels")
  Assert.equal(#gb1.warnings, 0)
  Assert.equal(#gb2.warnings, 0)
  -- A must not inherit B's provenance-derived nodes.
  Assert.equal(g2.nodes["src:0843:009:0000"], nil, "A must not inherit B's nodes")
  Assert.deepEqual(gb1.nodes, gb2.nodes)
end

-- A failed call must not leave its opts or partial state for the next call:
-- wrapper registration is per invocation.
function T.failed_compile_does_not_contaminate_later_calls()
  local script = S.script({ api = 1, id = "x", steps = { S.next() } })
  compileError("SCRIPT_WRAPPER_INVALID", script)
  local graph = compile(script, { allowNext = true })
  Assert.isTrue(graph.usesNext)
  compileError("SCRIPT_WRAPPER_INVALID", script)
end

-- The provenance node-id dedup counter starts fresh per call, so identical
-- generated scripts compile to identical ids every time.
function T.used_node_ids_reset_per_call()
  local function generated()
    return S.script({
      api = 1,
      id = "x",
      metadata = { generated = true, source = { member = 843, scriptIndex = 9 } },
      steps = {
        { op = "noop", provenance = { offsets = { 0x00 }, opcodes = { 0 } } },
      },
    })
  end
  local g1 = compile(generated())
  local g2 = compile(generated())
  Assert.equal(g1.entry, "src:0843:009:0000")
  Assert.equal(g2.entry, "src:0843:009:0000")
  Assert.deepEqual(g1.nodes, g2.nodes)
  Assert.equal(g1.revision, g2.revision)
end

-- opts is the one unvalidated compiler input: a metatable on opts can trigger
-- a nested compile while the outer compile is mid-flight. Compiler state must
-- be per call, so neither graph can absorb the other's nodes.
function T.reentrant_compile_does_not_contaminate_either_graph()
  local outer = S.script({
    api = 1,
    id = "outer",
    steps = { S.next(), S.setFlag({ flag = "FLAG_F" }) },
  })
  local inner = S.script({
    api = 1,
    id = "inner",
    steps = { S.setVar({ variable = "VAR_A", value = 1 }) },
  })
  local captured = {}
  local opts = setmetatable({}, {
    __index = function()
      captured.graph = compile(inner)
      return true
    end,
  })
  local graph = compile(outer, opts)
  Assert.isTrue(captured.graph ~= nil, "nested compile must have run")
  Assert.isTrue(graph.usesNext)
  Assert.deepEqual(graph.nodes["path:steps/0"], { op = "next" })
  Assert.deepEqual(graph.nodes["path:steps/1"], { op = "set_flag", flag = "FLAG_F" })
  Assert.deepEqual(captured.graph.nodes["path:steps/0"], { op = "set_var", variable = "VAR_A", value = 1 })
end

return T
