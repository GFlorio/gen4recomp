-- Authoritative public schema for the gen4 field-script DSL, API 1. This is
-- the single source of truth the constructors, validator, and doc generator
-- share: operation names, field names, types, defaults, enums, and the
-- normative constructor index. API 1 is the current version, still under
-- development, so shapes may change with the version; field shapes, enums,
-- and the constructor index live here and nowhere else.
local Schema = {}

Schema.API_VERSION = 1
Schema.SCRIPT_KIND = "field_script"
Schema.SCHEMA_NAME = "gen4-script-schema-v1"

-- Declared param/local value types.
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
    "slower",
    "slow",
    "normal",
    "fast",
    "faster",
    "slightly_fast",
    "slightly_faster",
    "fastest",
    "run",
    "hgss_96",
    "hgss_97",
    "hgss_98",
    "hgss_99",
  },
  jump_distance = { "zero", "near", "far" },
  text_pad = { "none", "zero", "space" },
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

Schema.ACTOR_SPECIALS = { "player", "self", "last_talked", "partner", "camera_target" }

-- Script resource schema . `kind` is constructor-supplied;
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

-- General value references. Each kind's fields
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

-- Text-value descriptors. Descriptors are never
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
  party_species_name = { fields = { position = { type = "scalar_or_value", required = true } } },
  party_nickname = { fields = { position = { type = "scalar_or_value", required = true } } },
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

-- Condition references.
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

-- Movement actions. A movement sequence is an
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

-- Canonical operations . Every step is a table with `op` set
-- to one of these names and the declared fields; unknown fields are rejected.
Schema.OPERATIONS = {
  noop = { fields = {} },
  stop = { fields = {} },
  yield_tick = { fields = {} },
  set_auxiliary_ui_visible = {
    fields = {
      visible = { type = "boolean", required = true },
    },
  },
  context_choice = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  wait_ticks = {
    fields = {
      ticks = { type = "integer", required = true },
      -- Observable countdown mirror : when the source
      -- destination variable is read elsewhere, the task mirrors the
      -- countdown into it exactly like ScrCmd_Wait + RunPauseTimer (initial
      -- write at creation, one decrement per poll). Without this field the
      -- countdown stays internal to the task state.
      countdownVariable = { type = "id_or_var" },
    },
  },
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
      -- Optional cross-script entry label: the call enters the composed
      -- target at this label instead of its entry (shared script tails).
      -- Only valid when the target is not a local label.
      label = { type = "string" },
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
  -- Translator-internal caller-signal operation : lowered from
  -- HGSS `RestartCurrentScript` inside verified common-script contexts. Not
  -- exposed as a public constructor; generated scripts may use it and
  -- handwritten scripts are warned.
  signal_caller = { fields = {} },
  ["return"] = { fields = { value = { type = "scalar_or_value" } } },
  label = { fields = { name = { type = "string", required = true } } },
  ["goto"] = { fields = { target = { type = "string", required = true } } },
  goto_if = {
    fields = {
      condition = { type = "condition", required = true },
      target = { type = "string", required = true },
    },
  },
  -- Cross-script jump (shared script tails, rows 22/28):
  -- a same-context, same-tick jump into another script's graph, resolved
  -- through the composition registry at runtime like the raw-Lua escape
  -- hatch. `label` names an entry point inside the target; without it the
  -- jump lands on the composed target's entry. Handwritten scripts are
  -- warned (same bucket as label/goto fallback).
  goto_script = {
    fields = {
      script = { type = "string", required = true },
      label = { type = "string" },
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
      -- Either a local label `target` or a cross-script reference (`script`
      -- plus optional `label`), resolved through the composition registry at
      -- runtime; the compare state is consumed exactly as the source does.
      target = { type = "string" },
      script = { type = "string" },
      label = { type = "string" },
    },
  },
  call_compared = {
    fields = {
      operator = { type = "enum:compare_operator", required = true },
      target = { type = "string" },
      script = { type = "string" },
      label = { type = "string" },
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
      wait = { type = "enum:say_wait", default = "button" },
      close = { type = "boolean", default = true },
      timingProfile = { type = "enum:timing_profile", default = "hgss" },
      bindings = { type = "bindings", default = {} },
    },
  },
  open_message = { fields = {} },
  message = {
    fields = {
      message = { type = "message", required = true },
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
  -- Generated/advanced HGSS menu-builder operations. Handwritten scripts
  -- should use `choose` once the public semantic API lands.
  menu_begin = {
    fields = {
      messageSource = { type = "serializable", required = true },
      sourcePlacement = { type = "serializable", required = true },
      initialCursor = { type = "integer", required = true },
      cancellable = { type = "boolean", required = true },
      result = { type = "value", required = true },
    },
  },
  menu_add = {
    fields = {
      messageId = { type = "scalar_or_value", required = true },
      vanillaMetadata = { type = "scalar_or_value", required = true },
      value = { type = "scalar_or_value", required = true },
    },
  },
  menu_exec = { fields = {} },
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
      fieldX = { type = "scalar_or_value", required = true },
      fieldZ = { type = "scalar_or_value", required = true },
      worldY = { type = "scalar_or_value" },
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
  play_fanfare = { fields = { fanfare = { type = "scalar_or_value", required = true } } },
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
      map = { type = "scalar_or_value", required = true },
      warp = { type = "scalar_or_value", required = true },
      fieldX = { type = "scalar_or_value", required = true },
      fieldZ = { type = "scalar_or_value", required = true },
      facing = { type = "scalar_or_value", required = true },
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

-- Step-level fields shared by every operation . `key`
-- stabilizes a node's identity in the node map across non-semantic edits;
-- `provenance` carries source offsets/opcodes and drives generated `src:`
-- node IDs (the compiler maps it onto the node's `source` field). The step
-- field is named `provenance` because `copy_var` owns the `source` operand
-- name. Both are additive API 1 fields: identity and provenance, never
-- runtime semantics. Both drive node IDs, and node IDs are revision inputs:
-- the graph revision hashes a projection keyed by node ID, so author `key`
-- edits change the revision, and provenance identity edits do too for
-- generated `src:` nodes. Only the node `source` payload (opcodes, ...) is
-- excluded from that hash.
Schema.STEP_FIELDS = {
  key = { type = "string" },
  provenance = { type = "source_provenance" },
}
for _, op in pairs(Schema.OPERATIONS) do
  for name, spec in pairs(Schema.STEP_FIELDS) do
    op.fields[name] = spec
  end
end

-- Normative constructor index. Grouped exactly like the
-- spec tables; the doc generator renders this into docs/script-api-v1.md.
Schema.CONSTRUCTORS = {
  {
    section = "Resource and reference constructors",
    rows = {
      {
        signature = "S.script(spec)",
        canonical = 'kind="field_script"',
        notes = "Requires api, id, and steps; supplies kind.",
      },
      { signature = "S.var(id)", canonical = 'value="var"', notes = "Persistent/project-owned variable reference." },
      {
        signature = "S.local_(name)",
        canonical = 'value="local"',
        notes = "Instance-local reference. Trailing underscore is part of API.",
      },
      { signature = "S.arg(name)", canonical = 'value="arg"', notes = "Call argument reference." },
      { signature = "S.actor(id)", canonical = 'ref="actor", id=id', notes = "Map/public actor ID." },
      { signature = "S.player()", canonical = 'ref="actor", special="player"', notes = "" },
      { signature = "S.self()", canonical = 'ref="actor", special="self"', notes = "Trigger-owning object." },
      { signature = "S.lastTalked()", canonical = 'ref="actor", special="last_talked"', notes = "" },
      { signature = "S.partner()", canonical = 'ref="actor", special="partner"', notes = "" },
      { signature = "S.cameraTarget()", canonical = 'ref="actor", special="camera_target"', notes = "" },
      {
        signature = "S.actorIndex(index)",
        canonical = 'ref="actor", mapIndex=index',
        notes = "Numeric local map-object index resolved against the current map at runtime.",
      },
      {
        signature = "S.externalMessage(bank, id)",
        canonical = 'message="external"',
        notes = "Both operands may be values.",
      },
    },
  },
  {
    section = "Text-value constructors",
    rows = {
      { signature = "S.playerName()", canonical = "text=player_name", notes = "" },
      { signature = "S.rivalName()", canonical = "text=rival_name", notes = "" },
      { signature = "S.friendName()", canonical = "text=friend_name", notes = "" },
      { signature = "S.integerText(value)", canonical = "text=integer", notes = "" },
      { signature = "S.itemName(value)", canonical = "text=item_name", notes = "" },
      { signature = "S.pocketName(value)", canonical = "text=pocket_name", notes = "" },
      { signature = "S.moveName(value)", canonical = "text=move_name", notes = "" },
      { signature = "S.tmhmMoveName(value)", canonical = "text=tmhm_move_name", notes = "" },
      { signature = "S.speciesName(value)", canonical = "text=species_name", notes = "" },
      {
        signature = "S.partySpeciesName(position)",
        canonical = "text=party_species_name",
        notes = "Read-only party lookup.",
      },
      { signature = "S.partyNickname(position)", canonical = "text=party_nickname", notes = "Read-only party lookup." },
      { signature = "S.trainerClassName(value)", canonical = "text=trainer_class_name", notes = "" },
      {
        signature = "S.starterSpeciesName()",
        canonical = "text=starter_species_name",
        notes = "Read-only world-state lookup.",
      },
      { signature = "S.mapName(value)", canonical = "text=map_name", notes = "" },
      {
        signature = "S.gendered(maleMessage, femaleMessage)",
        canonical = "text=gendered_message",
        notes = "Message selection, not rendered text concatenation.",
      },
    },
  },
  {
    section = "General value constructors",
    rows = {
      {
        signature = "S.flagValue(flag)",
        canonical = "value=flag_value",
        notes = "Returns numeric 1 or 0; flag may be static or dynamic.",
      },
      {
        signature = "S.playerGenderValue()",
        canonical = "value=player_gender_value",
        notes = "HGSS-compatible numeric value.",
      },
      {
        signature = "S.objectIdValue(ref)",
        canonical = "value=object_id",
        notes = "Used by imported trigger comparisons.",
      },
      {
        signature = "S.backgroundIdValue()",
        canonical = "value=trigger_background_id",
        notes = "Reads current trigger context.",
      },
      {
        signature = "S.triggerDirectionValue()",
        canonical = "value=trigger_direction",
        notes = "Reads normalized trigger direction.",
      },
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
    notes = "All step constructors take one canonical spec table (the schema field names); generated scripts emit raw canonical step tables and never call these.",
    rows = {
      { signature = "S.noop(spec)", canonical = "op=noop", notes = "spec optional." },
      { signature = "S.stop(spec)", canonical = "op=stop", notes = "Normal script completion; spec optional." },
      {
        signature = "S.yieldTick(spec)",
        canonical = "op=yield_tick",
        notes = "Generated/advanced explicit one-tick source yield; spec optional.",
      },
      {
        signature = "S.setAuxiliaryUiVisible(spec)",
        canonical = "op=set_auxiliary_ui_visible",
        notes = "spec={visible=boolean}; imported HGSS visibility synchronization blocks as needed.",
      },
      {
        signature = "S.waitTicks(spec)",
        canonical = "op=wait_ticks",
        notes = "spec={ticks>=1,countdownVariable=nil}; first poll next tick, continuation one tick after completion; countdownVariable mirrors the countdown into an observable variable like the source engine.",
      },
      { signature = "S.if_(spec)", canonical = "op=if", notes = "spec={condition,yes={},no={}}." },
      { signature = "S.switch(spec)", canonical = "op=switch", notes = "spec={value,cases,default={}}." },
      {
        signature = "S.call(spec)",
        canonical = "op=call",
        notes = "spec={target,args={},result=nil,label=nil}; label enters the composed target at a label instead of its entry.",
      },
      {
        signature = "S.callCommon(spec)",
        canonical = "op=call_common",
        notes = "Generated/advanced common child context; spec={target,args={}}.",
      },
      {
        signature = "S.return_(spec)",
        canonical = "op=return",
        notes = "Trailing underscore is part of API; spec={value=nil}.",
      },
      { signature = "S.label(spec)", canonical = "op=label", notes = "spec={name}; generated fallback." },
      { signature = "S.goto_(spec)", canonical = "op=goto", notes = "spec={target}; generated fallback." },
      {
        signature = "S.gotoIf(spec)",
        canonical = "op=goto_if",
        notes = "spec={condition,target}; generated fallback.",
      },
      {
        signature = "S.gotoScript(spec)",
        canonical = "op=goto_script",
        notes = "spec={script,label=nil}; cross-script same-context jump (shared script tails); resolved through the composition registry at runtime; handwritten scripts are warned.",
      },
      {
        signature = "S.compare(spec)",
        canonical = "op=compare",
        notes = "spec={left,right}; generated low-level fallback.",
      },
      {
        signature = "S.gotoCompared(spec)",
        canonical = "op=goto_compared",
        notes = "spec={operator,target=nil,script=nil,label=nil}; the script/label form is cross-script, resolved through the composition registry at runtime.",
      },
      {
        signature = "S.callCompared(spec)",
        canonical = "op=call_compared",
        notes = "spec={operator,target=nil,script=nil,label=nil}; the script/label form is cross-script.",
      },
      { signature = "S.next(spec)", canonical = "op=next", notes = "Wrapper resources only; spec optional." },
    },
  },
  {
    section = "State constructors",
    rows = {
      { signature = "S.setFlag(spec)", canonical = "op=set_flag", notes = "spec={flag}." },
      { signature = "S.clearFlag(spec)", canonical = "op=clear_flag", notes = "spec={flag}." },
      { signature = "S.setVar(spec)", canonical = "op=set_var", notes = "spec={variable,value}." },
      {
        signature = "S.copyVar(spec)",
        canonical = "op=copy_var",
        notes = "spec={destination,source}; source is a variable ID.",
      },
      { signature = "S.addVar(spec)", canonical = "op=add_var", notes = "spec={variable,amount}." },
      { signature = "S.subVar(spec)", canonical = "op=sub_var", notes = "spec={variable,amount}." },
      { signature = "S.setLocal(spec)", canonical = "op=set_local", notes = "spec={name,value}." },
      { signature = "S.copyLocal(spec)", canonical = "op=copy_local", notes = "spec={destination,source}." },
      { signature = "S.addLocal(spec)", canonical = "op=add_local", notes = "spec={name,amount}." },
      { signature = "S.subLocal(spec)", canonical = "op=sub_local", notes = "spec={name,amount}." },
    },
  },
  {
    section = "Dialogue constructors",
    rows = {
      {
        signature = "S.say(spec)",
        canonical = "op=say",
        notes = 'spec={message,wait="button",close=true,timingProfile="hgss",bindings={}}.',
      },
      { signature = "S.openMessage(spec)", canonical = "op=open_message", notes = "spec optional." },
      {
        signature = "S.message(spec)",
        canonical = "op=message",
        notes = "spec={message,waitForPrint=true,bindings={}}; generated scripts emit waitForPrint explicitly.",
      },
      { signature = "S.waitInput(spec)", canonical = "op=wait_input", notes = "spec={buttons={a,b},allowDpad=false}." },
      {
        signature = "S.waitInputOrTicks(spec)",
        canonical = "op=wait_input_or_ticks",
        notes = 'spec={ticks,buttons={"a","b"},allowDpad=true,turnPlayerOnDpad=false}.',
      },
      { signature = "S.closeMessage(spec)", canonical = "op=close_message", notes = "spec={erase=true}." },
      { signature = "S.holdMessage(spec)", canonical = "op=hold_message", notes = "spec optional." },
      {
        signature = "S.askYesNo(spec)",
        canonical = "op=ask_yes_no",
        notes = "spec={message=nil,result,bindings={}}; message=nil uses current box.",
      },
      { signature = "S.bufferText(spec)", canonical = "op=buffer_text", notes = "spec={slot 0..7,value}." },
      { signature = "S.showWaitingIcon(spec)", canonical = "op=show_waiting_icon", notes = "spec optional." },
      { signature = "S.hideWaitingIcon(spec)", canonical = "op=hide_waiting_icon", notes = "spec optional." },
      {
        signature = "S.resolveCommonMessageBank(spec)",
        canonical = "op=resolve_common_message_bank",
        notes = "spec={script,bankResult,memberResult}.",
      },
    },
  },
  {
    section = "Lock and actor constructors",
    rows = {
      {
        signature = "S.lockPlayer(spec)",
        canonical = "op=lock_player",
        notes = "Player input and interaction only; spec optional.",
      },
      { signature = "S.releasePlayer(spec)", canonical = "op=release_player", notes = "spec optional." },
      {
        signature = "S.lockAll(spec)",
        canonical = "op=lock_all",
        notes = "Player plus autonomous behavior; returns yield_tick or blocks until pausable; spec optional.",
      },
      {
        signature = "S.releaseAll(spec)",
        canonical = "op=release_all",
        notes = "Handwritten semantic is immediate; imported HGSS emits a following yield_tick; spec optional.",
      },
      {
        signature = "S.lockActor(spec)",
        canonical = "op=lock_actor",
        notes = "spec={actor,waitUntilPausable=false}; imported LockLastTalked sets true.",
      },
      { signature = "S.releaseActor(spec)", canonical = "op=release_actor", notes = "spec={actor}." },
      {
        signature = "S.facePlayer(spec)",
        canonical = "op=face_player",
        notes = 'spec={actor=nil}; actor defaults to "self" when omitted.',
      },
      {
        signature = "S.face(spec)",
        canonical = "op=face",
        notes = "spec={actor,direction}; immediate facing operation.",
      },
      { signature = "S.showObject(spec)", canonical = "op=show_object", notes = "spec={actor}." },
      { signature = "S.hideObject(spec)", canonical = "op=hide_object", notes = "spec={actor}." },
      {
        signature = "S.setObjectPosition(spec)",
        canonical = "op=set_object_position",
        notes = "spec={actor,fieldX,fieldZ,worldY=nil}.",
      },
      { signature = "S.setObjectFacing(spec)", canonical = "op=set_object_facing", notes = "spec={actor,direction}." },
      {
        signature = "S.setObjectMovementType(spec)",
        canonical = "op=set_object_movement_type",
        notes = "spec={actor,movementType}.",
      },
      { signature = "S.getPlayerCoords(spec)", canonical = "op=get_player_coords", notes = "spec={x,z} result refs." },
      {
        signature = "S.getObjectCoords(spec)",
        canonical = "op=get_object_coords",
        notes = "spec={actor,x,z} result refs.",
      },
      { signature = "S.getPlayerFacing(spec)", canonical = "op=get_player_facing", notes = "spec={result}." },
    },
  },
  {
    section = "Movement constructors",
    rows = {
      {
        signature = "S.applyMovement(spec)",
        canonical = "op=apply_movement",
        notes = "spec={actor,movement,{movementId=nil}}; non-blocking.",
      },
      {
        signature = "S.waitMovement(spec)",
        canonical = "op=wait_movement",
        notes = 'spec=nil means current environment generation; actor scope uses {scope="actors",actors={...}}.',
      },
      { signature = "S.move(spec)", canonical = "op=move", notes = "spec={actor,movement}; blocking convenience." },
    },
  },
  {
    section = "Movement action namespace",
    rows = {
      { signature = "S.m.face(spec)", canonical = "action=face", notes = "spec={direction,count=1}." },
      { signature = "S.m.walk(spec)", canonical = "action=walk", notes = 'spec={direction,speed="normal",tiles=1}.' },
      {
        signature = "S.m.walkInPlace(spec)",
        canonical = "action=walk_in_place",
        notes = 'spec={direction,speed="normal",count=1}.',
      },
      {
        signature = "S.m.jump(spec)",
        canonical = "action=jump",
        notes = 'spec={direction,distance="zero",speed="fast",count=1}.',
      },
      { signature = "S.m.delay(spec)", canonical = "action=delay", notes = "spec={ticks,count=1}." },
      { signature = "S.m.setVisible(spec)", canonical = "action=set_visible", notes = "spec={visible}." },
      { signature = "S.m.lockFacing(spec)", canonical = "action=lock_facing", notes = "spec optional." },
      { signature = "S.m.unlockFacing(spec)", canonical = "action=unlock_facing", notes = "spec optional." },
      { signature = "S.m.pauseAnimation(spec)", canonical = "action=pause_animation", notes = "spec optional." },
      { signature = "S.m.resumeAnimation(spec)", canonical = "action=resume_animation", notes = "spec optional." },
      { signature = "S.m.emote(spec)", canonical = "action=emote", notes = "spec={name,count=1}." },
      { signature = "S.m.gesture(spec)", canonical = "action=gesture", notes = "spec={name,count=1}." },
      {
        signature = "S.m.unsupported(spec)",
        canonical = "action=unsupported",
        notes = "Requires source code/count metadata.",
      },
    },
  },
  {
    section = "Audio constructors",
    rows = {
      { signature = "S.playSound(spec)", canonical = "op=play_sound", notes = "spec={sound}." },
      { signature = "S.stopSound(spec)", canonical = "op=stop_sound", notes = "spec={sound}." },
      {
        signature = "S.waitSound(spec)",
        canonical = "op=wait_sound",
        notes = "spec={sound=nil}; missing ID waits for the currently tracked effect.",
      },
      { signature = "S.playCry(spec)", canonical = "op=play_cry", notes = "spec={species,form=0}." },
      { signature = "S.waitCry(spec)", canonical = "op=wait_cry", notes = "spec optional." },
      { signature = "S.playFanfare(spec)", canonical = "op=play_fanfare", notes = "spec={fanfare}." },
      { signature = "S.waitFanfare(spec)", canonical = "op=wait_fanfare", notes = "spec optional." },
      { signature = "S.playMusic(spec)", canonical = "op=play_music", notes = "spec={music}." },
      {
        signature = "S.stopMusic(spec)",
        canonical = "op=stop_music",
        notes = "spec={music=nil}; missing ID stops the active field BGM.",
      },
      { signature = "S.resetMusic(spec)", canonical = "op=reset_music", notes = "spec optional." },
      { signature = "S.temporaryMusic(spec)", canonical = "op=temporary_music", notes = "spec={music}." },
      { signature = "S.fadeMusicOut(spec)", canonical = "op=fade_music_out", notes = "spec={target=0,durationTicks}." },
      { signature = "S.fadeMusicIn(spec)", canonical = "op=fade_music_in", notes = "spec={durationTicks}." },
    },
  },
  {
    section = "Screen, camera, and map constructors",
    rows = {
      {
        signature = "S.fadeScreen(spec)",
        canonical = "op=fade_screen",
        notes = "Requires source kind/speed/direction/color or normalized equivalents.",
      },
      { signature = "S.waitFade(spec)", canonical = "op=wait_fade", notes = "spec optional." },
      { signature = "S.warp(spec)", canonical = "op=warp", notes = "Requires map and target coordinates/warp." },
      { signature = "S.setSpawn(spec)", canonical = "op=set_spawn", notes = "spec={spawn}." },
      {
        signature = "S.shakeCamera(spec)",
        canonical = "op=shake_camera",
        notes = "Requires amplitude/interval/count fields.",
      },
    },
  },
  {
    section = "Random, raw, and diagnostic constructors",
    rows = {
      { signature = "S.random(spec)", canonical = "op=random", notes = "spec={maxExclusive,result}." },
      {
        signature = "S.lua(spec)",
        canonical = "op=lua",
        notes = "Requires module and fn; defaults args={}, result=nil.",
      },
      {
        signature = "S.unsupported(spec)",
        canonical = "op=unsupported",
        notes = "Requires command/name/source metadata sufficient for diagnostics.",
      },
    },
  },
}

return Schema
