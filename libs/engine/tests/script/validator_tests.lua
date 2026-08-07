-- Validator tests for the gen4 field-script API 1 data contract. They prove
-- the exit criterion of Workstream 1: a script can be loaded (constructor or
-- direct table), validated, and deterministically printed without any game
-- session. Rejection cases cover non-serializable data, unknown fields, API
-- version mismatches, and malformed references.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local LuaWriter = require("libs.rom.src.LuaWriter")
local S = require("gen4.script")

local T = {}

-- Public validation returns nil, err instead of raising.
---@param code string
---@param script any
---@param opts table|nil
---@return Errors.Error
local function invalidCode(code, script, opts)
  local ok, err = S.validate(script, opts)
  Assert.isNil(ok)
  Assert.isTrue(Errors.is(err), "expected Errors object, got: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
  return err
end

local function valid(script, opts)
  local ok, err = S.validate(script, opts)
  Assert.isTrue(ok, "expected valid script, got: " .. tostring(err))
end

local function womanScript()
  return S.script {
    api = 1,
    id = "new_bark.npc.woman_1",
    steps = {
      S.playSound("SEQ_SE_DP_SELECT"),
      S.lockAll(),
      S.facePlayer("self"),
      S.if_ {
        condition = S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 0),
        yes = { S.say("msg.hgss.0542.00009") },
        no = {
          S.if_ {
            condition = S.any {
              S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 1),
              S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 2),
            },
            yes = { S.say("msg.hgss.0542.00005") },
            no = {
              S.if_ {
                condition = S.eq(S.var("VAR_SCENE_NEW_BARK_WEST_EXIT"), 1),
                yes = { S.say("msg.hgss.0542.00000") },
                no = {
                  S.bufferText(0, S.playerName()),
                  S.say(S.gendered("msg.hgss.0542.00006", "msg.hgss.0542.00007")),
                },
              },
            },
          },
        },
      },
      S.releaseAll(),
    },
  }
end

local function signScript()
  return S.script {
    api = 1,
    id = "new_bark.lab_sign",
    steps = {
      S.playSound("SEQ_SE_DP_SELECT"),
      S.lockAll(),
      S.say("msg.hgss.0543.00097"),
      S.releaseAll(),
    },
  }
end

function T.accepts_minimal_direct_table_script()
  valid {
    api = 1,
    id = "mod.example.sign",
    steps = { { op = "stop" } },
  }
end

function T.accepts_vertical_slice_scripts()
  valid(womanScript())
  valid(signScript())
end

function T.direct_table_equivalents_validate_identically()
  local script = S.script {
    api = 1,
    id = "new_bark.lab_sign",
    steps = { S.say("msg.hgss.0543.00097") },
  }
  local direct = {
    kind = "field_script",
    api = 1,
    id = "new_bark.lab_sign",
    steps = {
      { op = "say", message = "msg.hgss.0543.00097", style = "npc", wait = "button", close = true, timingProfile = "hgss", bindings = {} },
    },
  }
  Assert.deepEqual(script, direct)
  valid(script)
  valid(direct)
end

function T.script_must_be_a_table()
  invalidCode("SCRIPT_SCHEMA_INVALID", "not a script")
  invalidCode("SCRIPT_SCHEMA_INVALID", nil)
end

function T.rejects_unsupported_api_version()
  local err = invalidCode("SCRIPT_API_UNSUPPORTED", { api = 2, id = "x", steps = { S.stop() } })
  Assert.equal(err.context.api, 2)
  Assert.equal(err.context.path, "api")
end

function T.rejects_non_integer_api()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = "1", id = "x", steps = { S.stop() } })
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1.5, id = "x", steps = { S.stop() } })
end

function T.rejects_missing_id_and_steps()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, steps = { S.stop() } })
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x" })
end

function T.rejects_unknown_script_kind()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", kind = "overworld_script", steps = { S.stop() } })
end

function T.rejects_unknown_operation()
  local err = invalidCode("SCRIPT_UNKNOWN_OPERATION", { api = 1, id = "x", steps = { { op = "teleport_to_kanto" } } })
  Assert.equal(err.context.path, "steps/0")
end

function T.rejects_step_without_op()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { { style = "npc" } } })
end

function T.rejects_non_table_step()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { "S.stop()" } })
end

function T.rejects_missing_required_field()
  local err = invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { { op = "say" } } })
  Assert.equal(err.context.field, "message")
  Assert.equal(err.context.path, "steps/0/message")
end

function T.rejects_bad_enum_value()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { { op = "face", actor = "elm", direction = "northwest" } } })
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.m.walk("south", { speed = "warp" }) } })
end

function T.rejects_unknown_param_type()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    params = { professor = "gym_leader_ref" },
    steps = { S.stop() },
  })
end

function T.accepts_all_param_types()
  valid {
    api = 1,
    id = "x",
    params = {
      a = "bool",
      b = "integer",
      c = "number",
      d = "string",
      e = "id",
      f = "actor_ref",
      g = "map_ref",
      h = "message_ref",
      i = "movement_ref",
      j = "serializable",
    },
    locals = { route = "string" },
    steps = { S.stop() },
  }
end

function T.rejects_undeclared_local_and_arg_usage()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.setLocal("route", "intro") },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.say(S.arg("message")) },
  })
end

function T.rejects_functions_in_script_data()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { function() end } })
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.stop() }, metadata = { callback = function() end } })
end

function T.rejects_userdata()
  local userdata = io.open("/dev/null", "r")
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.stop() }, metadata = { file = userdata } })
  if userdata then userdata:close() end
end

function T.rejects_threads()
  local thread = coroutine.create(function() end)
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.stop() }, metadata = { thread = thread } })
end

function T.rejects_cyclic_tables()
  local steps = { S.stop() }
  steps[1].selfRef = steps
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = steps })
end

function T.rejects_metatables()
  local step = S.stop()
  setmetatable(step, {})
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { step } })
end

function T.rejects_non_finite_numbers()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { { op = "wait_ticks", ticks = 1 / 0 } } })
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.stop() }, metadata = { nan = 0 / 0 } })
end

function T.rejects_unknown_fields_in_strict_mode()
  local script = {
    api = 1,
    id = "x",
    steps = { { op = "stop", surprise = true } },
  }
  local err = invalidCode("SCRIPT_SCHEMA_INVALID", script)
  Assert.equal(err.context.field, "surprise")
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.stop() }, extra = 1 })
end

function T.non_strict_mode_ignores_unknown_fields()
  valid(
    {
      api = 1,
      id = "x",
      steps = { { op = "stop", surprise = true } },
    },
    { strict = false }
  )
end

function T.rejects_unknown_value_kind()
  invalidCode("SCRIPT_INVALID_REFERENCE", { api = 1, id = "x", steps = { S.setVar("VAR_A", { value = "heap_pointer" }) } })
end

function T.rejects_malformed_value_reference()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.setVar("VAR_A", { other = 1 }) } })
end

function T.rejects_unknown_condition_kind()
  invalidCode("SCRIPT_INVALID_REFERENCE", {
    api = 1,
    id = "x",
    steps = { S.if_ { condition = { condition = "scripted_fate" }, yes = {}, no = {} } },
  })
end

function T.rejects_bad_compare_operator()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.if_ { condition = { condition = "compare", operator = "approx", left = 1, right = 2 }, yes = {}, no = {} } },
  })
end

function T.rejects_invalid_actor_reference()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.showObject({ ref = "actor", special = "the_void" }) } })
  invalidCode("SCRIPT_INVALID_REFERENCE", { api = 1, id = "x", steps = { S.showObject({ ref = "prop", id = "sign" }) } })
end

function T.rejects_invalid_movement_action()
  invalidCode("SCRIPT_UNKNOWN_OPERATION", { api = 1, id = "x", steps = { S.applyMovement("elm", { { action = "moonwalk", count = 1 } }) } })
end

function T.rejects_invalid_message_reference()
  local err = invalidCode("SCRIPT_INVALID_REFERENCE", { api = 1, id = "x", steps = { S.say({ text = "species_name", value = "SPECIES_PIKACHU" }) } })
  Assert.equal(err.context.path, "steps/0/message")
end

function T.rejects_bad_switch_cases()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.switch { value = S.var("v"), cases = { [0] = { { op = "stop" } }, a = {} } } },
  })
end

function T.error_contexts_carry_path_and_script_id()
  local err = invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "new_bark.lab_sign",
    steps = {
      S.say("msg.hgss.0543.00097"),
      S.if_ {
        condition = S.flag("FLAG_MET_ELM"),
        yes = { { op = "face", actor = "elm", direction = "northwest" } },
        no = {},
      },
    },
  })
  Assert.equal(err.context.scriptId, "new_bark.lab_sign")
  Assert.equal(err.context.path, "steps/1/yes/0/direction")
end

-- Exit criterion: load, normalize, validate, print — deterministically, with
-- no game session. LuaWriter output must reload to the same validated script.
function T.script_loads_validates_and_prints_round_trip()
  for _, script in ipairs({ womanScript(), signScript() }) do
    valid(script)
    local printed = LuaWriter.encode(script)
    local chunk = assert(loadstring(printed), "printed script must compile")
    local loaded = chunk()
    Assert.deepEqual(loaded, script)
    valid(loaded)
  end
end

function T.constructor_and_direct_table_forms_print_identically()
  local constructorForm = S.script {
    api = 1,
    id = "x",
    steps = { S.say("msg.hgss.0543.00097") },
  }
  local directForm = {
    kind = "field_script",
    api = 1,
    id = "x",
    steps = {
      { op = "say", message = "msg.hgss.0543.00097", style = "npc", wait = "button", close = true, timingProfile = "hgss", bindings = {} },
    },
  }
  valid(constructorForm)
  valid(directForm)
  Assert.equal(LuaWriter.encode(constructorForm), LuaWriter.encode(directForm))
end

return T
