-- Authoritative public schema for the gen4 field-script DSL, API 1. This is
-- the single source of truth the constructors, validator, doc generator, and
-- compatibility tests share: operation names, field names, types, defaults,
-- enums, and the normative constructor index. The schema is frozen by the
-- sprint spec (tmp/spec.md): field shapes come from sections 8-14 and 45.1-45.2,
-- enums from sections 17.2 and 35.1, and the constructor index from section 45.

local Schema = {}

Schema.API_VERSION = 1
Schema.SCRIPT_KIND = "field_script"
Schema.SCHEMA_NAME = "gen4-script-schema-v1"

-- Declared param/local value types (spec section 9.2).
Schema.PARAM_TYPES = {
  "bool",
  "integer",
  "number",
  "string",
  "id",
  "actor_ref",
  "map_ref",
  "message_ref",
  "movement_ref",
  "serializable",
}

-- Enum values. Field specs reference these as "enum:<name>".
Schema.ENUMS = {
  script_kind = { Schema.SCRIPT_KIND },
  direction = { "north", "south", "west", "east" },
  speed = {
    "slower", "slow", "normal", "fast", "faster",
    "slightly_fast", "slightly_faster", "fastest",
    "run", "hgss_96", "hgss_97", "hgss_98", "hgss_99",
  },
  jump_distance = { "zero", "near", "far" },
  text_pad = { "none", "zero", "space" },
  dialogue_style = { "npc", "system" },
  say_wait = { "button" },
  timing_profile = { "hgss" },
  movement_scope = { "environment", "actors" },
  compare_operator = { "lt", "eq", "gt", "le", "ge", "ne" },
  emote = { "exclamation", "exclamation_alt", "question" },
  gesture = { "warp_out", "warp_in", "nurse_bow", "give", "receive" },
  fade_direction = { "in", "out" },
  fade_color = { "black", "white" },
  button = { "a", "b" },
}

-- Special actor references (spec section 10.2).
Schema.ACTOR_SPECIALS = { "player", "self", "last_talked", "partner" }

-- Script resource schema (spec section 9.2). `kind` is constructor-supplied;
-- direct tables may omit it.
Schema.SCRIPT = {
  fields = {
    kind = { type = "enum:script_kind", default = Schema.SCRIPT_KIND },
    api = { type = "integer", required = true },
    id = { type = "string", required = true },
    params = { type = "params" },
    locals = { type = "locals" },
    replaces = { type = "string" },
    steps = { type = "steps", required = true },
    metadata = { type = "serializable" },
  },
}

-- General value references (spec section 10.1 and 45.3). Each kind's fields
-- are validated against its own spec; unknown kinds are invalid references.
Schema.VALUES = {
  var = { fields = { id = { type = "string", required = true } } },
  ["local"] = { fields = { name = { type = "string", required = true } } },
  arg = { fields = { name = { type = "string", required = true } } },
  flag_value = { fields = { flag = { type = "id_or_var", required = true } } },
  player_gender_value = { fields = {} },
  object_id = { fields = { ref = { type = "actor", required = true } } },
  trigger_background_id = { fields = {} },
  trigger_direction = { fields = {} },
}

-- Text-value descriptors (spec section 10.3 and 45.2). Descriptors are never
-- eagerly rendered strings.
Schema.TEXT_VALUES = {
  player_name = { fields = {} },
  rival_name = { fields = {} },
  friend_name = { fields = {} },
  integer = {
    fields = {
      value = { type = "scalar_or_value", required = true },
      width = { type = "integer" },
      pad = { type = "enum:text_pad", default = "none" },
      sign = { type = "boolean", default = false },
    },
  },
  item_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  pocket_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  move_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  tmhm_move_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  species_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  party_species_name = { fields = { position = { type = "integer", required = true } } },
  party_nickname = { fields = { position = { type = "integer", required = true } } },
  trainer_class_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  starter_species_name = { fields = {} },
  map_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  gendered_message = {
    fields = {
      male = { type = "message", required = true },
      female = { type = "message", required = true },
    },
  },
}

-- Condition references (spec section 11 and 45.4).
Schema.CONDITIONS = {
  compare = {
    fields = {
      operator = { type = "enum:compare_operator", required = true },
      left = { type = "scalar_or_value", required = true },
      right = { type = "scalar_or_value", required = true },
    },
  },
  flag = {
    fields = {
      id = { type = "id_or_var", required = true },
      expected = { type = "boolean", default = true },
    },
  },
  ["not"] = { fields = { operand = { type = "condition", required = true } } },
  all = { fields = { conditions = { type = "condition_list", default = {} } } },
  any = { fields = { conditions = { type = "condition_list", default = {} } } },
  actor_exists = { fields = { ref = { type = "actor", required = true } } },
  truthy = { fields = { value = { type = "scalar_or_value", required = true } } },
}

-- Movement actions (spec section 17.2 and 35.1). A movement sequence is an
-- array of these.
Schema.MOVEMENT_ACTIONS = {
  face = {
    fields = {
      direction = { type = "enum:direction", required = true },
      count = { type = "integer", default = 1 },
    },
  },
  walk = {
    fields = {
      direction = { type = "enum:direction", required = true },
      speed = { type = "enum:speed", default = "normal" },
      tiles = { type = "integer", default = 1 },
    },
  },
  walk_in_place = {
    fields = {
      direction = { type = "enum:direction", required = true },
      speed = { type = "enum:speed", default = "normal" },
      count = { type = "integer", default = 1 },
    },
  },
  jump = {
    fields = {
      direction = { type = "enum:direction", required = true },
      distance = { type = "enum:jump_distance", default = "zero" },
      speed = { type = "enum:speed", default = "fast" },
      count = { type = "integer", default = 1 },
    },
  },
  delay = {
    fields = {
      ticks = { type = "integer", required = true },
      count = { type = "integer", default = 1 },
    },
  },
  set_visible = { fields = { visible = { type = "boolean", required = true } } },
  lock_facing = { fields = {} },
  unlock_facing = { fields = {} },
  pause_animation = { fields = {} },
  resume_animation = { fields = {} },
  emote = {
    fields = {
      name = { type = "enum:emote", required = true },
      count = { type = "integer", default = 1 },
    },
  },
  gesture = {
    fields = {
      name = { type = "enum:gesture", required = true },
      count = { type = "integer", default = 1 },
    },
  },
  unsupported = {
    fields = {
      code = { type = "integer", required = true },
      count = { type = "integer", default = 1 },
      originalName = { type = "string" },
    },
  },
}

-- Canonical operations (spec section 45). Every step is a table with `op` set
-- to one of these names and the declared fields; unknown fields are rejected
-- in strict mode.
Schema.OPERATIONS = {
  noop = { fields = {} },
  stop = { fields = {} },
  yield_tick = { fields = {} },
  wait_ticks = { fields = { ticks = { type = "integer", required = true } } },
  ["if"] = {
    fields = {
      condition = { type = "condition", required = true },
      yes = { type = "steps", required = true },
      no = { type = "steps", default = {} },
    },
  },
  switch = {
    fields = {
      value = { type = "scalar_or_value", required = true },
      cases = { type = "cases", required = true },
      default = { type = "steps", default = {} },
    },
  },
  call = {
    fields = {
      target = { type = "string", required = true },
      args = { type = "args", default = {} },
      result = { type = "value" },
    },
  },
  call_common = {
    fields = {
      target = { type = "string", required = true },
      args = { type = "args", default = {} },
    },
  },
  ["return"] = { fields = { value = { type = "scalar_or_value" } } },
  label = { fields = { name = { type = "string", required = true } } },
  goto = { fields = { target = { type = "string", required = true } } },
  goto_if = {
    fields = {
      condition = { type = "condition", required = true },
      target = { type = "string", required = true },
    },
  },
  compare = {
    fields = {
      left = { type = "scalar_or_value", required = true },
      right = { type = "scalar_or_value", required = true },
    },
  },
  goto_compared = {
    fields = {
      operator = { type = "enum:compare_operator", required = true },
      target = { type = "string", required = true },
    },
  },
  call_compared = {
    fields = {
      operator = { type = "enum:compare_operator", required = true },
      target = { type = "string", required = true },
    },
  },
  next = { fields = {} },
  set_flag = { fields = { flag = { type = "id_or_var", required = true } } },
  clear_flag = { fields = { flag = { type = "id_or_var", required = true } } },
  set_var = {
    fields = {
      variable = { type = "id_or_var", required = true },
      value = { type = "scalar_or_value", required = true },
    },
  },
  copy_var = {
    fields = {
      destination = { type = "id_or_var", required = true },
      source = { type = "id_or_var", required = true },
    },
  },
  add_var = {
    fields = {
      variable = { type = "id_or_var", required = true },
      amount = { type = "scalar_or_value", required = true },
    },
  },
  sub_var = {
    fields = {
      variable = { type = "id_or_var", required = true },
      amount = { type = "scalar_or_value", required = true },
    },
  },
  set_local = {
    fields = {
      name = { type = "string", required = true },
      value = { type = "scalar", required = true },
    },
  },
  copy_local = {
    fields = {
      destination = { type = "string", required = true },
      source = { type = "string", required = true },
    },
  },
  add_local = {
    fields = {
      name = { type = "string", required = true },
      amount = { type = "scalar", required = true },
    },
  },
  sub_local = {
    fields = {
      name = { type = "string", required = true },
      amount = { type = "scalar", required = true },
    },
  },
  say = {
    fields = {
      message = { type = "message", required = true },
      style = { type = "enum:dialogue_style", default = "npc" },
      wait = { type = "enum:say_wait", default = "button" },
      close = { type = "boolean", default = true },
      timingProfile = { type = "enum:timing_profile", default = "hgss" },
      bindings = { type = "bindings", default = {} },
    },
  },
  open_message = { fields = { style = { type = "enum:dialogue_style", default = "npc" } } },
  message = {
    fields = {
      message = { type = "message", required = true },
      style = { type = "enum:dialogue_style", default = "npc" },
      waitForPrint = { type = "boolean", default = true },
      bindings = { type = "bindings", default = {} },
    },
  },
  wait_input = {
    fields = {
      buttons = { type = "buttons", default = { "a", "b" } },
      allowDpad = { type = "boolean", default = false },
      turnPlayerOnDpad = { type = "boolean", default = false },
    },
  },
  wait_input_or_ticks = {
    fields = {
      ticks = { type = "integer", required = true },
      buttons = { type = "buttons", default = { "a", "b" } },
      allowDpad = { type = "boolean", default = true },
      turnPlayerOnDpad = { type = "boolean", default = false },
    },
  },
  close_message = { fields = { erase = { type = "boolean", default = true } } },
  hold_message = { fields = {} },
  ask_yes_no = {
    fields = {
      message = { type = "message" },
      result = { type = "value", required = true },
      bindings = { type = "bindings", default = {} },
    },
  },
  buffer_text = {
    fields = {
      slot = { type = "buffer_slot", required = true },
      value = { type = "text_value", required = true },
    },
  },
  show_waiting_icon = { fields = {} },
  hide_waiting_icon = { fields = {} },
  resolve_common_message_bank = {
    fields = {
      script = { type = "string", required = true },
      bankResult = { type = "value", required = true },
      memberResult = { type = "value", required = true },
    },
  },
  lock_player = { fields = {} },
  release_player = { fields = {} },
  lock_all = { fields = {} },
  release_all = { fields = {} },
  lock_actor = {
    fields = {
      actor = { type = "actor", required = true },
      waitUntilPausable = { type = "boolean", default = false },
    },
  },
  release_actor = { fields = { actor = { type = "actor", required = true } } },
  face_player = { fields = { actor = { type = "actor", default = "self" } } },
  face = {
    fields = {
      actor = { type = "actor", required = true },
      direction = { type = "enum:direction", required = true },
    },
  },
  show_object = { fields = { actor = { type = "actor", required = true } } },
  hide_object = { fields = { actor = { type = "actor", required = true } } },
  set_object_position = {
    fields = {
      actor = { type = "actor", required = true },
      fieldX = { type = "integer", required = true },
      fieldZ = { type = "integer", required = true },
      worldY = { type = "number" },
    },
  },
  set_object_facing = {
    fields = {
      actor = { type = "actor", required = true },
      direction = { type = "enum:direction", required = true },
    },
  },
  set_object_movement_type = {
    fields = {
      actor = { type = "actor", required = true },
      movementType = { type = "string", required = true },
    },
  },
  get_player_coords = {
    fields = {
      x = { type = "value", required = true },
      z = { type = "value", required = true },
    },
  },
  get_object_coords = {
    fields = {
      actor = { type = "actor", required = true },
      x = { type = "value", required = true },
      z = { type = "value", required = true },
    },
  },
  get_player_facing = { fields = { result = { type = "value", required = true } } },
  apply_movement = {
    fields = {
      actor = { type = "actor", required = true },
      movement = { type = "movement", required = true },
      movementId = { type = "string" },
    },
  },
  wait_movement = {
    fields = {
      scope = { type = "enum:movement_scope", default = "environment" },
      actors = { type = "actor_list" },
    },
  },
  move = {
    fields = {
      actor = { type = "actor", required = true },
      movement = { type = "movement", required = true },
      movementId = { type = "string" },
    },
  },
  play_sound = { fields = { sound = { type = "string", required = true } } },
  stop_sound = { fields = { sound = { type = "string", required = true } } },
  wait_sound = { fields = { sound = { type = "string" } } },
  play_cry = {
    fields = {
      species = { type = "scalar_or_value", required = true },
      form = { type = "integer", default = 0 },
    },
  },
  wait_cry = { fields = {} },
  play_fanfare = { fields = { fanfare = { type = "string", required = true } } },
  wait_fanfare = { fields = {} },
  play_music = { fields = { music = { type = "string", required = true } } },
  stop_music = { fields = { music = { type = "string" } } },
  reset_music = { fields = {} },
  temporary_music = { fields = { music = { type = "string", required = true } } },
  fade_music_out = {
    fields = {
      target = { type = "integer", default = 0 },
      durationTicks = { type = "integer", required = true },
    },
  },
  fade_music_in = { fields = { durationTicks = { type = "integer", required = true } } },
  fade_screen = {
    fields = {
      kind = { type = "integer", required = true },
      speed = { type = "integer", required = true },
      direction = { type = "enum:fade_direction", required = true },
      color = { type = "enum:fade_color", required = true },
    },
  },
  wait_fade = { fields = {} },
  warp = {
    fields = {
      map = { type = "string", required = true },
      warp = { type = "integer", required = true },
      fieldX = { type = "integer", required = true },
      fieldZ = { type = "integer", required = true },
      facing = { type = "enum:direction", required = true },
    },
  },
  set_spawn = { fields = { spawn = { type = "string", required = true } } },
  shake_camera = {
    fields = {
      amplitudeX = { type = "number", required = true },
      amplitudeY = { type = "number", required = true },
      intervalTicks = { type = "integer", required = true },
      count = { type = "integer", required = true },
    },
  },
  random = {
    fields = {
      maxExclusive = { type = "integer", required = true },
      result = { type = "value", required = true },
    },
  },
  lua = {
    fields = {
      module = { type = "string", required = true },
      fn = { type = "string", required = true },
      args = { type = "args", default = {} },
      result = { type = "value" },
    },
  },
  unsupported = {
    fields = {
      command = { type = "integer", required = true },
      originalName = { type = "string" },
      arguments = { type = "scalar_list", default = {} },
      sourceOffset = { type = "integer" },
      reason = { type = "string" },
    },
  },
}

-- Normative constructor index (spec section 45). Grouped exactly like the
-- spec tables; the doc generator renders this into docs/script-api-v1.md.
Schema.CONSTRUCTORS = {
  {
    section = "Resource and reference constructors",
    rows = {
      { signature = "S.script(spec)", canonical = 'kind="field_script"', notes = "Requires api, id, and steps; supplies kind." },
      { signature = "S.var(id)", canonical = 'value="var"', notes = "Persistent/project-owned variable reference." },
      { signature = "S.local_(name)", canonical = 'value="local"', notes = "Instance-local reference. Trailing underscore is part of API." },
      { signature = "S.arg(name)", canonical = 'value="arg"', notes = "Call argument reference." },
      { signature = "S.actor(id)", canonical = 'ref="actor", id=id', notes = "Map/public actor ID." },
      { signature = "S.player()", canonical = 'ref="actor", special="player"', notes = "" },
      { signature = "S.self()", canonical = 'ref="actor", special="self"', notes = "Trigger-owning object." },
      { signature = "S.lastTalked()", canonical = 'ref="actor", special="last_talked"', notes = "" },
      { signature = "S.partner()", canonical = 'ref="actor", special="partner"', notes = "" },
      { signature = "S.externalMessage(bank, id)", canonical = 'message="external"', notes = "Both operands may be values." },
    },
  },
  {
    section = "Text-value constructors",
    rows = {
      { signature = "S.playerName()", canonical = "text=player_name", notes = "" },
      { signature = "S.rivalName()", canonical = "text=rival_name", notes = "" },
      { signature = "S.friendName()", canonical = "text=friend_name", notes = "" },
      { signature = "S.integerText(value, opts)", canonical = "text=integer", notes = 'opts={width=nil,pad="none",sign=false}; width omitted when nil.' },
      { signature = "S.itemName(value)", canonical = "text=item_name", notes = "" },
      { signature = "S.pocketName(value)", canonical = "text=pocket_name", notes = "" },
      { signature = "S.moveName(value)", canonical = "text=move_name", notes = "" },
      { signature = "S.tmhmMoveName(value)", canonical = "text=tmhm_move_name", notes = "" },
      { signature = "S.speciesName(value)", canonical = "text=species_name", notes = "" },
      { signature = "S.partySpeciesName(position)", canonical = "text=party_species_name", notes = "Read-only party lookup." },
      { signature = "S.partyNickname(position)", canonical = "text=party_nickname", notes = "Read-only party lookup." },
      { signature = "S.trainerClassName(value)", canonical = "text=trainer_class_name", notes = "" },
      { signature = "S.starterSpeciesName()", canonical = "text=starter_species_name", notes = "Read-only world-state lookup." },
      { signature = "S.mapName(value)", canonical = "text=map_name", notes = "" },
      { signature = "S.gendered(maleMessage, femaleMessage)", canonical = "text=gendered_message", notes = "Message selection, not rendered text concatenation." },
    },
  },
  {
    section = "General value constructors",
    rows = {
      { signature = "S.flagValue(flag)", canonical = "value=flag_value", notes = "Returns numeric 1 or 0; flag may be static or dynamic." },
      { signature = "S.playerGenderValue()", canonical = "value=player_gender_value", notes = "HGSS-compatible numeric value." },
      { signature = "S.objectIdValue(ref)", canonical = "value=object_id", notes = "Used by imported trigger comparisons." },
      { signature = "S.backgroundIdValue()", canonical = "value=trigger_background_id", notes = "Reads current trigger context." },
      { signature = "S.triggerDirectionValue()", canonical = "value=trigger_direction", notes = "Reads normalized trigger direction." },
    },
  },
  {
    section = "Condition constructors",
    rows = {
      { signature = "S.eq(a, b)", canonical = "compare eq", notes = "" },
      { signature = "S.ne(a, b)", canonical = "compare ne", notes = "" },
      { signature = "S.lt(a, b)", canonical = "compare lt", notes = "" },
      { signature = "S.le(a, b)", canonical = "compare le", notes = "" },
      { signature = "S.gt(a, b)", canonical = "compare gt", notes = "" },
      { signature = "S.ge(a, b)", canonical = "compare ge", notes = "" },
      { signature = "S.flag(idOrValue)", canonical = "flag", notes = "expected true." },
      { signature = "S.not_(condition)", canonical = "not", notes = "Trailing underscore is part of API." },
      { signature = "S.all(conditions)", canonical = "all", notes = "Empty list is true." },
      { signature = "S.any(conditions)", canonical = "any", notes = "Empty list is false." },
      { signature = "S.exists(actorRef)", canonical = "actor_exists", notes = "" },
      { signature = "S.truthy(value)", canonical = "truthy", notes = "Only false and nil are false." },
    },
  },
  {
    section = "Control-flow constructors",
    rows = {
      { signature = "S.noop()", canonical = "op=noop", notes = "" },
      { signature = "S.stop()", canonical = "op=stop", notes = "Normal script completion." },
      { signature = "S.yieldTick()", canonical = "op=yield_tick", notes = "Generated/advanced explicit one-tick source yield." },
      { signature = "S.waitTicks(ticks)", canonical = "op=wait_ticks", notes = "ticks >= 1; first poll next tick, continuation one tick after completion." },
      { signature = "S.if_(spec)", canonical = "op=if", notes = "spec={condition,yes={},no={}}." },
      { signature = "S.switch(spec)", canonical = "op=switch", notes = "spec={value,cases,default={}}." },
      { signature = "S.call(scriptId, opts)", canonical = "op=call", notes = "Same-context call; opts={args={},result=nil}." },
      { signature = "S.callCommon(scriptId, opts)", canonical = "op=call_common", notes = "Generated/advanced common child context; opts={args={}}." },
      { signature = "S.return_([value])", canonical = "op=return", notes = "Trailing underscore is part of API." },
      { signature = "S.label(name)", canonical = "op=label", notes = "Generated fallback." },
      { signature = "S.goto_(name)", canonical = "op=goto", notes = "Generated fallback." },
      { signature = "S.gotoIf(condition, name)", canonical = "op=goto_if", notes = "Generated fallback." },
      { signature = "S.compare(a, b)", canonical = "op=compare", notes = "Generated low-level fallback." },
      { signature = "S.gotoCompared(operator, name)", canonical = "op=goto_compared", notes = "Generated low-level fallback." },
      { signature = "S.callCompared(operator, target)", canonical = "op=call_compared", notes = "Generated low-level fallback." },
      { signature = "S.next()", canonical = "op=next", notes = "Wrapper resources only." },
    },
  },
  {
    section = "State constructors",
    rows = {
      { signature = "S.setFlag(flag)", canonical = "op=set_flag", notes = "" },
      { signature = "S.clearFlag(flag)", canonical = "op=clear_flag", notes = "" },
      { signature = "S.setVar(id, value)", canonical = "op=set_var", notes = "" },
      { signature = "S.copyVar(dst, src)", canonical = "op=copy_var", notes = "src is a variable ID." },
      { signature = "S.addVar(id, amount)", canonical = "op=add_var", notes = "" },
      { signature = "S.subVar(id, amount)", canonical = "op=sub_var", notes = "" },
      { signature = "S.setLocal(name, value)", canonical = "op=set_local", notes = "" },
      { signature = "S.copyLocal(dst, src)", canonical = "op=copy_local", notes = "" },
      { signature = "S.addLocal(name, amount)", canonical = "op=add_local", notes = "" },
      { signature = "S.subLocal(name, amount)", canonical = "op=sub_local", notes = "" },
    },
  },
  {
    section = "Dialogue constructors",
    rows = {
      { signature = "S.say(message, opts)", canonical = "op=say", notes = 'opts={style="npc",wait="button",close=true,timingProfile="hgss",bindings={}}.' },
      { signature = "S.openMessage(opts)", canonical = "op=open_message", notes = 'opts={style="npc"}.' },
      { signature = "S.message(message, opts)", canonical = "op=message", notes = 'opts={style="npc",waitForPrint=true,bindings={}}; generated scripts emit waitForPrint explicitly.' },
      { signature = "S.waitInput(opts)", canonical = "op=wait_input", notes = "Requires/accepts buttons; defaults {a,b}, no d-pad." },
      { signature = "S.waitInputOrTicks(opts)", canonical = "op=wait_input_or_ticks", notes = 'opts={ticks,buttons={"a","b"},allowDpad=true,turnPlayerOnDpad=false}.' },
      { signature = "S.closeMessage(opts)", canonical = "op=close_message", notes = "opts={erase=true}." },
      { signature = "S.holdMessage()", canonical = "op=hold_message", notes = "" },
      { signature = "S.askYesNo(message, opts)", canonical = "op=ask_yes_no", notes = "message=nil uses current box; opts={result,bindings={}}." },
      { signature = "S.bufferText(slot, value)", canonical = "op=buffer_text", notes = "Slot is 0..7." },
      { signature = "S.showWaitingIcon()", canonical = "op=show_waiting_icon", notes = "" },
      { signature = "S.hideWaitingIcon()", canonical = "op=hide_waiting_icon", notes = "" },
      { signature = "S.resolveCommonMessageBank(spec)", canonical = "op=resolve_common_message_bank", notes = "spec={script,bankResult,memberResult}." },
    },
  },
  {
    section = "Lock and actor constructors",
    rows = {
      { signature = "S.lockPlayer()", canonical = "op=lock_player", notes = "Player input and interaction only." },
      { signature = "S.releasePlayer()", canonical = "op=release_player", notes = "" },
      { signature = "S.lockAll()", canonical = "op=lock_all", notes = "Player plus autonomous behavior; returns yield_tick or blocks until pausable." },
      { signature = "S.releaseAll()", canonical = "op=release_all", notes = "Handwritten semantic is immediate; imported HGSS emits a following yield_tick." },
      { signature = "S.lockActor(actor, opts)", canonical = "op=lock_actor", notes = "opts={waitUntilPausable=false}; imported LockLastTalked sets true." },
      { signature = "S.releaseActor(actor)", canonical = "op=release_actor", notes = "" },
      { signature = "S.facePlayer(actor)", canonical = "op=face_player", notes = 'actor defaults to "self" when omitted.' },
      { signature = "S.face(actor, direction)", canonical = "op=face", notes = "Immediate facing operation." },
      { signature = "S.showObject(actor)", canonical = "op=show_object", notes = "" },
      { signature = "S.hideObject(actor)", canonical = "op=hide_object", notes = "" },
      { signature = "S.setObjectPosition(actor, position)", canonical = "op=set_object_position", notes = "Position requires fieldX and fieldZ; worldY optional." },
      { signature = "S.setObjectFacing(actor, direction)", canonical = "op=set_object_facing", notes = "" },
      { signature = "S.setObjectMovementType(actor, movementType)", canonical = "op=set_object_movement_type", notes = "" },
      { signature = "S.getPlayerCoords(spec)", canonical = "op=get_player_coords", notes = "spec={x,z} result refs." },
      { signature = "S.getObjectCoords(actor, spec)", canonical = "op=get_object_coords", notes = "spec={x,z} result refs." },
      { signature = "S.getPlayerFacing(spec)", canonical = "op=get_player_facing", notes = "spec={result}." },
    },
  },
  {
    section = "Movement constructors",
    rows = {
      { signature = "S.applyMovement(actor, sequence, opts)", canonical = "op=apply_movement", notes = "opts={movementId=nil}; non-blocking." },
      { signature = "S.waitMovement(opts)", canonical = "op=wait_movement", notes = 'opts=nil means current environment generation; actor scope uses {scope="actors",actors={...}}.' },
      { signature = "S.move(actor, sequence, opts)", canonical = "op=move", notes = "Blocking convenience; opts={}." },
    },
  },
  {
    section = "Movement action namespace",
    rows = {
      { signature = "S.m.face(direction, [count])", canonical = "action=face", notes = "count=1." },
      { signature = "S.m.walk(direction, opts)", canonical = "action=walk", notes = 'opts={speed="normal",tiles=1}.' },
      { signature = "S.m.walkInPlace(direction, opts)", canonical = "action=walk_in_place", notes = 'opts={speed="normal",count=1}.' },
      { signature = "S.m.jump(direction, opts)", canonical = "action=jump", notes = 'opts={distance="zero",speed="fast",count=1}.' },
      { signature = "S.m.delay(ticks, [count])", canonical = "action=delay", notes = "count=1." },
      { signature = "S.m.setVisible(visible)", canonical = "action=set_visible", notes = "" },
      { signature = "S.m.lockFacing()", canonical = "action=lock_facing", notes = "" },
      { signature = "S.m.unlockFacing()", canonical = "action=unlock_facing", notes = "" },
      { signature = "S.m.pauseAnimation()", canonical = "action=pause_animation", notes = "" },
      { signature = "S.m.resumeAnimation()", canonical = "action=resume_animation", notes = "" },
      { signature = "S.m.emote(name, [count])", canonical = "action=emote", notes = "count=1." },
      { signature = "S.m.gesture(name, [count])", canonical = "action=gesture", notes = "count=1." },
      { signature = "S.m.unsupported(spec)", canonical = "action=unsupported", notes = "Requires source code/count metadata." },
    },
  },
  {
    section = "Audio constructors",
    rows = {
      { signature = "S.playSound(id)", canonical = "op=play_sound", notes = "" },
      { signature = "S.stopSound(id)", canonical = "op=stop_sound", notes = "" },
      { signature = "S.waitSound([id])", canonical = "op=wait_sound", notes = "Missing ID waits for the currently tracked effect." },
      { signature = "S.playCry(species, opts)", canonical = "op=play_cry", notes = "opts={form=0}." },
      { signature = "S.waitCry()", canonical = "op=wait_cry", notes = "" },
      { signature = "S.playFanfare(id)", canonical = "op=play_fanfare", notes = "" },
      { signature = "S.waitFanfare()", canonical = "op=wait_fanfare", notes = "" },
      { signature = "S.playMusic(id)", canonical = "op=play_music", notes = "" },
      { signature = "S.stopMusic([id])", canonical = "op=stop_music", notes = "Missing ID stops the active field BGM." },
      { signature = "S.resetMusic()", canonical = "op=reset_music", notes = "" },
      { signature = "S.temporaryMusic(id)", canonical = "op=temporary_music", notes = "" },
      { signature = "S.fadeMusicOut(spec)", canonical = "op=fade_music_out", notes = "spec={target=0,durationTicks}." },
      { signature = "S.fadeMusicIn(spec)", canonical = "op=fade_music_in", notes = "spec={durationTicks}." },
    },
  },
  {
    section = "Screen, camera, and map constructors",
    rows = {
      { signature = "S.fadeScreen(spec)", canonical = "op=fade_screen", notes = "Requires source kind/speed/direction/color or normalized equivalents." },
      { signature = "S.waitFade()", canonical = "op=wait_fade", notes = "" },
      { signature = "S.warp(spec)", canonical = "op=warp", notes = "Requires map and target coordinates/warp." },
      { signature = "S.setSpawn(spawn)", canonical = "op=set_spawn", notes = "" },
      { signature = "S.shakeCamera(spec)", canonical = "op=shake_camera", notes = "Requires amplitude/interval/count fields." },
    },
  },
  {
    section = "Random, raw, and diagnostic constructors",
    rows = {
      { signature = "S.random(spec)", canonical = "op=random", notes = "spec={maxExclusive,result}." },
      { signature = "S.lua(spec)", canonical = "op=lua", notes = "Requires module and fn; defaults args={}, result=nil." },
      { signature = "S.unsupported(spec)", canonical = "op=unsupported", notes = "Requires command/name/source metadata sufficient for diagnostics." },
    },
  },
}

return Schema
