-- Lua DSL emitter : renders a structured script resource
-- as deterministic, byte-stable gen4 DSL Lua. Output uses stable key order,
-- one trailing newline, no timestamps, and no machine-specific paths;
-- re-running against identical inputs produces byte-identical files. Every
-- generated step carries provenance. Pure domain module: no love dependency.

local LuaEmitter = {}

local LUA_KEYWORDS = {
  ["and"] = true,
  ["break"] = true,
  ["do"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["end"] = true,
  ["false"] = true,
  ["for"] = true,
  ["function"] = true,
  ["goto"] = true,
  ["if"] = true,
  ["in"] = true,
  ["local"] = true,
  ["nil"] = true,
  ["not"] = true,
  ["or"] = true,
  ["repeat"] = true,
  ["return"] = true,
  ["then"] = true,
  ["true"] = true,
  ["until"] = true,
  ["while"] = true,
}

-- Deterministic key order for table emission (fields first, then sorted).
---@param t table
---@return string[]
local function orderedKeys(t)
  local fields, others = {}, {}
  for key in pairs(t) do
    if type(key) == "number" then
      fields[#fields + 1] = key
    else
      others[#others + 1] = key
    end
  end
  table.sort(fields)
  table.sort(others)
  for _, key in ipairs(others) do
    fields[#fields + 1] = key
  end
  return fields
end

local writer

-- A fixed, readable constructor index for the generated steps.
local CONSTRUCTORS = {
  noop = "noop",
  stop = "stop",
  yield_tick = "yieldTick",
  wait_ticks = "waitTicks",
  ["if"] = "if_",
  switch = "switch",
  call = "call",
  call_common = "callCommon",
  ["return"] = "return_",
  label = "label",
  ["goto"] = "goto_",
  goto_if = "gotoIf",
  goto_script = "gotoScript",
  goto_compared = "gotoCompared",
  call_compared = "callCompared",
  next = "next",
  set_flag = "setFlag",
  clear_flag = "clearFlag",
  set_var = "setVar",
  copy_var = "copyVar",
  add_var = "addVar",
  sub_var = "subVar",
  set_local = "setLocal",
  copy_local = "copyLocal",
  add_local = "addLocal",
  sub_local = "subLocal",
  say = "say",
  open_message = "openMessage",
  message = "message",
  wait_input = "waitInput",
  wait_input_or_ticks = "waitInputOrTicks",
  close_message = "closeMessage",
  hold_message = "holdMessage",
  ask_yes_no = "askYesNo",
  buffer_text = "bufferText",
  show_waiting_icon = "showWaitingIcon",
  hide_waiting_icon = "hideWaitingIcon",
  lock_player = "lockPlayer",
  release_player = "releasePlayer",
  lock_all = "lockAll",
  release_all = "releaseAll",
  lock_actor = "lockActor",
  release_actor = "releaseActor",
  face_player = "facePlayer",
  face = "face",
  show_object = "showObject",
  hide_object = "hideObject",
  set_object_position = "setObjectPosition",
  set_object_facing = "setObjectFacing",
  set_object_movement_type = "setObjectMovementType",
  get_player_coords = "getPlayerCoords",
  get_object_coords = "getObjectCoords",
  get_player_facing = "getPlayerFacing",
  apply_movement = "applyMovement",
  wait_movement = "waitMovement",
  move = "move",
  play_sound = "playSound",
  stop_sound = "stopSound",
  wait_sound = "waitSound",
  play_cry = "playCry",
  wait_cry = "waitCry",
  play_fanfare = "playFanfare",
  wait_fanfare = "waitFanfare",
  play_music = "playMusic",
  stop_music = "stopMusic",
  reset_music = "resetMusic",
  temporary_music = "temporaryMusic",
  fade_music_out = "fadeMusicOut",
  fade_music_in = "fadeMusicIn",
  fade_screen = "fadeScreen",
  wait_fade = "waitFade",
  warp = "warp",
  set_spawn = "setSpawn",
  shake_camera = "shakeCamera",
  random = "random",
  lua = "lua",
  unsupported = "unsupported",
  signal_caller = "signal_caller",
}

-- Literal rendering for operands (values, refs, conditions, messages).
---@param value any
---@param indent string
---@return string
local function literal(value, indent)
  local ty = type(value)
  if ty == "nil" then
    return "nil"
  end
  if ty == "boolean" then
    return value and "true" or "false"
  end
  if ty == "number" then
    return tostring(value)
  end
  if ty == "string" then
    return string.format("%q", value)
  end
  -- Dispatch order matters: a text descriptor carries both `.text` and
  -- `.value`, so the more specific shapes must win over the generic value
  -- reference (otherwise `writer.value` stringifies the nested table).
  if value.condition ~= nil then
    return writer.condition(value, indent)
  end
  if value.text ~= nil then
    return writer.text(value, indent)
  end
  if value.ref == "actor" then
    return writer.actor(value)
  end
  if value.message ~= nil then
    return writer.message(value, indent)
  end
  if value.value ~= nil then
    if value.value == "var" then
      return "S.var(" .. string.format("%q", value.id) .. ")"
    elseif value.value == "local" then
      return "S.local_(" .. string.format("%q", value.name) .. ")"
    elseif value.value == "arg" then
      return "S.arg(" .. string.format("%q", value.name) .. ")"
    end
    return writer.value(value, indent)
  end
  return writer.table(value, indent)
end

-- Render a serializable table with deterministic order.
---@param t table
---@param indent string
---@return string
local function tableLiteral(t, indent)
  local keys = orderedKeys(t)
  local parts = {}
  for _, key in ipairs(keys) do
    local keyText
    if type(key) == "number" then
      keyText = "[" .. tostring(key) .. "]"
    elseif key:match("^[%a_][%w_]*$") and not LUA_KEYWORDS[key] then
      keyText = key
    else
      keyText = "[" .. string.format("%q", key) .. "]"
    end
    parts[#parts + 1] = keyText .. " = " .. literal(t[key], indent .. "  ")
  end
  if #parts == 0 then
    return "{}"
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

writer = {
  value = function(value, indent)
    local fields = {}
    for _, key in ipairs(orderedKeys(value)) do
      if key ~= "value" then
        fields[#fields + 1] = key .. " = " .. literal(value[key], indent .. "  ")
      end
    end
    return "{ value = "
      .. string.format("%q", value.value)
      .. (#fields > 0 and ", " or "")
      .. table.concat(fields, ", ")
      .. " }"
  end,
  condition = function(condition, indent)
    local name = ({
      compare = "compare",
      flag = "flag",
      ["not"] = "not_",
      all = "all",
      any = "any",
      truthy = "truthy",
    })[condition.condition]
    if name == nil then
      return tableLiteral(condition, indent)
    end
    if name == "compare" then
      return string.format(
        "S.%s(%s, %s)",
        condition.operator,
        literal(condition.left, indent),
        literal(condition.right, indent)
      )
    elseif name == "flag" then
      local flag = literal(condition.id, indent)
      if condition.expected == false then
        return "S.not_(S.flag(" .. flag .. "))"
      end
      return "S.flag(" .. flag .. ")"
    elseif name == "not_" then
      return "S.not_(" .. literal(condition.operand, indent) .. ")"
    elseif name == "all" or name == "any" then
      local parts = {}
      for _, sub in ipairs(condition.conditions or {}) do
        parts[#parts + 1] = literal(sub, indent)
      end
      return "S." .. name .. " { " .. table.concat(parts, ", ") .. " }"
    elseif name == "exists" then
      return "S.exists(" .. literal(condition.ref, indent) .. ")"
    end
    return "S.truthy(" .. literal(condition.value, indent) .. ")"
  end,
  text = function(value, indent)
    local fields = {}
    for _, key in ipairs(orderedKeys(value)) do
      if key ~= "text" then
        fields[#fields + 1] = key .. " = " .. literal(value[key], indent .. "  ")
      end
    end
    return "{ text = "
      .. string.format("%q", value.text)
      .. (#fields > 0 and ", " or "")
      .. table.concat(fields, ", ")
      .. " }"
  end,
  actor = function(value)
    if value.special ~= nil then
      return "S."
        .. ({
          player = "player",
          self = "self",
          last_talked = "lastTalked",
          partner = "partner",
          camera_target = "cameraTarget",
        })[value.special]
        .. "()"
    end
    if value.mapIndex ~= nil then
      return string.format("S.actorIndex(%d)", value.mapIndex)
    end
    return string.format("S.actor(%q)", value.id)
  end,
  message = function(value, indent)
    if type(value) == "string" then
      return string.format("%q", value)
    end
    if value.message == "external" then
      return "S.externalMessage(" .. literal(value.bank, indent) .. ", " .. literal(value.id, indent) .. ")"
    end
    if value.text == "gendered_message" then
      return "S.gendered(" .. literal(value.male, indent) .. ", " .. literal(value.female, indent) .. ")"
    end
    return tableLiteral(value, indent)
  end,
  table = tableLiteral,
}

-- Render one movement action via the M namespace.
---@param action table
---@param indent string
---@return string
local function movementAction(action, indent)
  local name = action.action
  local constructor = ({
    face = "face",
    walk = "walk",
    walk_in_place = "walkInPlace",
    jump = "jump",
    delay = "delay",
    set_visible = "setVisible",
    lock_facing = "lockFacing",
    unlock_facing = "unlockFacing",
    pause_animation = "pauseAnimation",
    resume_animation = "resumeAnimation",
    emote = "emote",
    gesture = "gesture",
    unsupported = "unsupported",
  })[name]
  if constructor == nil then
    return tableLiteral(action, indent)
  end
  if name == "face" or name == "delay" then
    local direction = action.direction
    if name == "delay" then
      return string.format("S.m.delay(%d, %d)", action.ticks, action.count)
    end
    return string.format("S.m.face(%q, %d)", direction, action.count)
  elseif name == "unsupported" then
    return "S.m.unsupported { code = " .. tostring(action.code) .. ", count = " .. tostring(action.count) .. " }"
  elseif name == "set_visible" then
    return "S.m.setVisible(" .. tostring(action.visible) .. ")"
  elseif name == "emote" or name == "gesture" then
    return string.format("S.m.%s(%q, %d)", name, action.name, action.count)
  elseif name == "walk" then
    return string.format("S.m.walk(%q, { speed = %q, tiles = %d })", action.direction, action.speed, action.tiles)
  elseif name == "walk_in_place" then
    return string.format(
      "S.m.walkInPlace(%q, { speed = %q, count = %d })",
      action.direction,
      action.speed,
      action.count
    )
  elseif name == "jump" then
    return string.format(
      "S.m.jump(%q, { distance = %q, speed = %q, count = %d })",
      action.direction,
      action.distance,
      action.speed,
      action.count
    )
  end
  return tableLiteral(action, indent)
end

local renderSteps

-- The operation's constructor call. `opts.allowNext` marks wrapper scripts.
---@param step table
---@param indent string
---@param opts table
---@return string
local function stepText(step, indent, opts)
  local op = step.op
  local constructor = CONSTRUCTORS[op]
  if constructor == nil then
    return tableLiteral(step, indent)
  end
  if op == "label" then
    return string.format("S.label(%q)", step.name)
  elseif op == "goto_" then
    return string.format("S.goto_(%q)", step.target)
  elseif op == "goto_if" then
    return string.format("S.gotoIf(%s, %q)", literal(step.condition, indent), step.target)
  elseif op == "call" then
    local parts = {}
    if step.label ~= nil then
      parts[#parts + 1] = "label = " .. string.format("%q", step.label)
    end
    if #parts > 0 then
      return string.format("S.call(%q, { %s })", step.target, table.concat(parts, ", "))
    end
    return string.format("S.call(%q)", step.target)
  elseif op == "goto_script" then
    if step.label ~= nil then
      return string.format("S.gotoScript(%q, { label = %q })", step.script, step.label)
    end
    return string.format("S.gotoScript(%q)", step.script)
  elseif op == "if" then
    local yes = renderSteps(step.yes, indent .. "  ", opts)
    local no = renderSteps(step.no, indent .. "  ", opts)
    return "S.if_ {\n"
      .. indent
      .. "  condition = "
      .. literal(step.condition, indent)
      .. ",\n"
      .. indent
      .. "  yes = {\n"
      .. yes
      .. "\n"
      .. indent
      .. "  },"
      .. "\n"
      .. indent
      .. "  no = {\n"
      .. no
      .. "\n"
      .. indent
      .. "  },\n"
      .. indent
      .. "}"
  elseif op == "signal_caller" then
    -- Translator-internal caller-signal operation : no
    -- public constructor exists, so generated common scripts use the always-
    -- legal direct table form.
    return '{ op = "signal_caller" }'
  elseif
    op == "stop"
    or op == "next"
    or op == "hold_message"
    or op == "wait_movement"
    or op == "wait_cry"
    or op == "wait_fanfare"
    or op == "wait_fade"
    or op == "reset_music"
    or op == "show_waiting_icon"
    or op == "hide_waiting_icon"
    or op == "open_message"
    or op == "lock_all"
    or op == "release_all"
    or op == "lock_player"
    or op == "release_player"
    or op == "yield_tick"
    or op == "noop"
    or op == "face_player"
  then
    local zeroArg = {
      stop = "stop",
      next = "next",
      hold_message = "holdMessage",
      wait_movement = "waitMovement",
      wait_cry = "waitCry",
      wait_fanfare = "waitFanfare",
      wait_fade = "waitFade",
      reset_music = "resetMusic",
      show_waiting_icon = "showWaitingIcon",
      hide_waiting_icon = "hideWaitingIcon",
      open_message = "openMessage",
      lock_all = "lockAll",
      release_all = "releaseAll",
      lock_player = "lockPlayer",
      release_player = "releasePlayer",
      yield_tick = "yieldTick",
      noop = "noop",
      face_player = "facePlayer",
    }
    return "S." .. zeroArg[op] .. "()"
  elseif op == "unsupported" then
    local args = {}
    for _, argument in ipairs(step.arguments or {}) do
      args[#args + 1] = literal(argument, indent)
    end
    return "S.unsupported { command = "
      .. tostring(step.command)
      .. ", originalName = "
      .. string.format("%q", step.originalName or "")
      .. ", arguments = { "
      .. table.concat(args, ", ")
      .. (step.sourceOffset ~= nil and " }, sourceOffset = " .. tostring(step.sourceOffset) or " }")
      .. ", reason = "
      .. string.format("%q", step.reason or "")
      .. " }"
  end
  -- Generic: constructor(fields...) via a table call.
  local fields = {}
  for _, key in ipairs(orderedKeys(step)) do
    if
      key ~= "op"
      and key ~= "sourceNotes"
      and key ~= "yieldsNextTick"
      and key ~= "movementComplete"
      and key ~= "movementUnsupported"
      and key ~= "sourceFacing"
    then
      local value = step[key]
      if key == "provenance" then
        fields[#fields + 1] = "provenance = { offsets = { "
          .. table.concat(value.offsets, ", ")
          .. " }, opcodes = { "
          .. table.concat(value.opcodes, ", ")
          .. " } }"
      elseif key == "message" then
        fields[#fields + 1] = "message = " .. writer.message(value, indent .. "  ")
      elseif key == "movement" then
        local actions = {}
        for _, action in ipairs(value) do
          actions[#actions + 1] = movementAction(action, indent .. "  ")
        end
        fields[#fields + 1] = "movement = { " .. table.concat(actions, ", ") .. " }"
      elseif key == "bindings" then
        local bindings = {}
        for slot, textValue in pairs(value) do
          bindings[#bindings + 1] = "[" .. tostring(slot) .. "] = " .. literal(textValue, indent .. "  ")
        end
        table.sort(bindings)
        fields[#fields + 1] = "bindings = { " .. table.concat(bindings, ", ") .. " }"
      else
        fields[#fields + 1] = key .. " = " .. literal(value, indent .. "  ")
      end
    end
  end
  return "S." .. constructor .. " { " .. table.concat(fields, ", ") .. " }"
end

-- Render a steps array with a leading `steps = {` block.
---@param steps table[]
---@param indent string
---@param opts table
---@return string
renderSteps = function(steps, indent, opts)
  local parts = {}
  for _, step in ipairs(steps) do
    parts[#parts + 1] = indent .. "  " .. stepText(step, indent .. "  ", opts) .. ","
  end
  return table.concat(parts, "\n")
end

-- Render a full script resource.
---@param resource table
---@param meta table { member, scriptIndex, sourcePath, commit, repository,
---   sourceHash, game, coverage }
---@return string
function LuaEmitter.emit(resource, meta)
  local lines = {}
  lines[#lines + 1] = "-- Generated by hgss-script-translator ."
  lines[#lines + 1] = "-- Do not edit by hand; provenance below identifies the source."
  lines[#lines + 1] = 'local S = require("gen4.script")'
  lines[#lines + 1] = ""
  lines[#lines + 1] = "return S.script {"
  lines[#lines + 1] = "  api = 1,"
  lines[#lines + 1] = "  id = " .. string.format("%q", resource.id) .. ","
  lines[#lines + 1] = "  metadata = {"
  lines[#lines + 1] = "    generated = true,"
  lines[#lines + 1] = '    generator = { name = "hgss-script-translator", version = 1 },'
  lines[#lines + 1] = "    source = {"
  lines[#lines + 1] = "      repository = " .. string.format("%q", meta.repository) .. ","
  lines[#lines + 1] = "      commit = " .. string.format("%q", meta.commit) .. ","
  lines[#lines + 1] = "      path = " .. string.format("%q", meta.sourcePath) .. ","
  lines[#lines + 1] = "      game = " .. string.format("%q", meta.game or "heartgold") .. ","
  lines[#lines + 1] = '      archive = "scr_seq",'
  lines[#lines + 1] = "      member = " .. tostring(meta.member) .. ","
  lines[#lines + 1] = "      scriptIndex = " .. tostring(meta.scriptIndex) .. ","
  lines[#lines + 1] = "      sourceHash = " .. string.format("%q", meta.sourceHash or "") .. ","
  lines[#lines + 1] = "    },"
  lines[#lines + 1] = "    coverage = { complete = "
    .. tostring(meta.coverage.complete)
    .. ", unsupportedCount = "
    .. tostring(meta.coverage.unsupportedCount)
    .. " },"
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  steps = {"
  lines[#lines + 1] = renderSteps(resource.steps, "  ", { allowNext = meta.allowNext })
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

-- Render an override resource for `data/scripts/overrides/<id>.lua` (the
-- script override system): the supported flow of the translated script with
-- unsupported commands replaced by visible placeholders. Deterministic like
-- the cache emission; the header states the override origin and the
-- `replaces` field names the generated base when the override id is curated.
---@param resource table
---@param meta table { member, scriptIndex, sourcePath, replaces? }
---@return string
function LuaEmitter.emitOverride(resource, meta)
  local lines = {}
  lines[#lines + 1] = "-- Generated override (script override system): the supported flow of the"
  lines[#lines + 1] = "-- translated script with unsupported commands replaced by a visible"
  lines[#lines + 1] = "-- placeholder dialogue. Regenerate, do not hand-edit."
  lines[#lines + 1] = 'local S = require("gen4.script")'
  lines[#lines + 1] = ""
  lines[#lines + 1] = "return S.script {"
  lines[#lines + 1] = "  api = 1,"
  lines[#lines + 1] = "  id = " .. string.format("%q", resource.id) .. ","
  if meta.replaces ~= nil then
    lines[#lines + 1] = "  replaces = " .. string.format("%q", meta.replaces) .. ","
  end
  lines[#lines + 1] = "  metadata = {"
  lines[#lines + 1] = "    override = true,"
  lines[#lines + 1] = "    generated = true,"
  lines[#lines + 1] = '    generator = { name = "hgss-script-translator", version = 1 },'
  lines[#lines + 1] = "    source = {"
  lines[#lines + 1] = '      repository = "g4recomp",'
  lines[#lines + 1] = "      path = " .. string.format("%q", meta.sourcePath) .. ","
  lines[#lines + 1] = '      game = "heartgold",'
  lines[#lines + 1] = '      archive = "scr_seq",'
  lines[#lines + 1] = "      member = " .. tostring(meta.member) .. ","
  lines[#lines + 1] = "      scriptIndex = " .. tostring(meta.scriptIndex) .. ","
  lines[#lines + 1] = "    },"
  local coverage = resource.metadata and resource.metadata.coverage or { complete = true, unsupportedCount = 0 }
  lines[#lines + 1] = "    coverage = { complete = "
    .. tostring(coverage.complete == true)
    .. ", unsupportedCount = "
    .. tostring(coverage.unsupportedCount or 0)
    .. " },"
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  steps = {"
  lines[#lines + 1] = renderSteps(resource.steps, "  ", {})
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

return LuaEmitter
