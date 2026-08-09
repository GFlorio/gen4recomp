-- DSL constructors for the gen4 field-script platform, API 1. Constructors
-- return ordinary serializable Lua tables whose shapes are frozen by the
-- schema (libs/engine/src/script/Schema.lua) and the compatibility tests.
-- Defaults come from the schema so the doc generator, validator, and
-- constructors can never drift. The compiler, not these constructors,
-- normalizes shorthand (for example the actor string form).

local Schema = require("libs.engine.src.script.Schema")

local M = {}

local function copyDefault(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = v
  end
  return out
end

local function defaultsFor(fields)
  local out = {}
  for name, spec in pairs(fields) do
    if spec.default ~= nil then
      out[name] = copyDefault(spec.default)
    end
  end
  return out
end

local function mergeFields(kind, given)
  local fields = kind.fields
  local out = defaultsFor(fields)
  for k, v in pairs(given or {}) do
    out[k] = v
  end
  return out
end

local function op(kind, given)
  local spec = Schema.OPERATIONS[kind]
  assert(spec, "unknown operation: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.op = kind
  return out
end

-- Generated files call constructors with a spec table (`S.setVar { ... }`),
-- while the documented section 45 signatures are positional. A constructor
-- accepts a spec table when its first argument is a table carrying at least
-- one of the op's own field names (keys never present on value/actor/
-- condition/message reference tables), or any table when the positional
-- first argument is always a scalar.
local function asSpec(first, keys)
  if type(first) == "table" then
    if keys == nil then
      return first
    end
    for _, key in ipairs(keys) do
      if first[key] ~= nil then
        return first
      end
    end
  end
  return nil
end

-- Whether a table is a message/condition/value reference (never a step spec).
-- Used where the positional first argument may itself be a reference table.
local function looksLikeRef(t)
  return t.value ~= nil
    or t.ref ~= nil
    or t.condition ~= nil
    or t.text ~= nil
    or t.message == "external"
    or t.bank ~= nil
    or t.male ~= nil
end

local function value(kind, given)
  local spec = Schema.VALUES[kind]
  assert(spec, "unknown value kind: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.value = kind
  return out
end

local function text(kind, given)
  local spec = Schema.TEXT_VALUES[kind]
  assert(spec, "unknown text kind: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.text = kind
  return out
end

local function cond(kind, given)
  local spec = Schema.CONDITIONS[kind]
  assert(spec, "unknown condition kind: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.condition = kind
  return out
end

local function action(kind, given)
  local spec = Schema.MOVEMENT_ACTIONS[kind]
  assert(spec, "unknown movement action: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.action = kind
  return out
end

-- Argument assertion helpers. Constructors stay permissive about structure
-- (validation is separate), but catch clear caller mistakes early.
local function requireString(v, what)
  assert(type(v) == "string" and #v > 0, what .. " must be a non-empty string")
  return v
end

local function requireInteger(v, what)
  assert(type(v) == "number" and v % 1 == 0 and v == v, what .. " must be an integer")
  return v
end

local function requireTable(v, what)
  assert(type(v) == "table", what .. " must be a table")
  return v
end

-- Merge an optional options table over the given fields, dropping nil
-- values so unset optionals leave no keys behind.
local function extend(given, opts)
  if opts then
    for k, v in pairs(opts) do
      given[k] = v
    end
  end
  return given
end

local DIRECTION_SET = {}
for _, name in ipairs(Schema.ENUMS.direction) do
  DIRECTION_SET[name] = true
end

local function requireDirection(v)
  assert(
    type(v) == "string" and DIRECTION_SET[v] ~= nil,
    "direction must be one of: " .. table.concat(Schema.ENUMS.direction, ", ")
  )
  return v
end

-- 45.1 Resource and reference constructors

function M.script(spec)
  requireTable(spec, "script spec")
  assert(spec.api ~= nil, "script api is required")
  requireInteger(spec.api, "script api")
  assert(type(spec.id) == "string" and #spec.id > 0, "script id must be a non-empty string")
  requireTable(spec.steps, "script steps")
  local out = {}
  for k, v in pairs(spec) do
    out[k] = v
  end
  out.kind = Schema.SCRIPT_KIND
  return out
end

function M.var(id)
  return value("var", { id = requireString(id, "variable id") })
end

function M.local_(name)
  return value("local", { name = requireString(name, "local name") })
end

function M.arg(name)
  return value("arg", { name = requireString(name, "arg name") })
end

function M.actor(id)
  return { ref = "actor", id = requireString(id, "actor id") }
end

function M.player()
  return { ref = "actor", special = "player" }
end

function M.self()
  return { ref = "actor", special = "self" }
end

function M.lastTalked()
  return { ref = "actor", special = "last_talked" }
end

function M.partner()
  return { ref = "actor", special = "partner" }
end

function M.cameraTarget()
  return { ref = "actor", special = "camera_target" }
end

-- A numeric local map-object index, resolved against the current map at
-- runtime (the pinned HGSS object-id path).
---@param index integer
---@return table
function M.actorIndex(index)
  return { ref = "actor", mapIndex = requireInteger(index, "actor map index") }
end

function M.externalMessage(bank, id)
  return { message = "external", bank = bank, id = id }
end

-- 45.2 Text-value constructors

function M.playerName()
  return text("player_name")
end
function M.rivalName()
  return text("rival_name")
end
function M.friendName()
  return text("friend_name")
end

function M.integerText(value, opts)
  local given = { value = value }
  extend(given, opts)
  return text("integer", given)
end

function M.itemName(v)
  return text("item_name", { value = v })
end
function M.pocketName(v)
  return text("pocket_name", { value = v })
end
function M.moveName(v)
  return text("move_name", { value = v })
end
function M.tmhmMoveName(v)
  return text("tmhm_move_name", { value = v })
end
function M.speciesName(v)
  return text("species_name", { value = v })
end

function M.partySpeciesName(position)
  return text("party_species_name", { position = requireInteger(position, "party position") })
end

function M.partyNickname(position)
  return text("party_nickname", { position = requireInteger(position, "party position") })
end

function M.trainerClassName(v)
  return text("trainer_class_name", { value = v })
end
function M.starterSpeciesName()
  return text("starter_species_name")
end
function M.mapName(v)
  return text("map_name", { value = v })
end

function M.gendered(maleMessage, femaleMessage)
  return text("gendered_message", { male = maleMessage, female = femaleMessage })
end

-- 45.3 General value constructors

function M.flagValue(flag)
  return value("flag_value", { flag = flag })
end

function M.playerGenderValue()
  return value("player_gender_value")
end

function M.objectIdValue(ref)
  return value("object_id", { ref = ref })
end

function M.backgroundIdValue()
  return value("trigger_background_id")
end

function M.triggerDirectionValue()
  return value("trigger_direction")
end

-- 45.4 Condition constructors

local function compareOp(operator, a, b)
  return cond("compare", { operator = operator, left = a, right = b })
end

function M.eq(a, b)
  return compareOp("eq", a, b)
end
function M.ne(a, b)
  return compareOp("ne", a, b)
end
function M.lt(a, b)
  return compareOp("lt", a, b)
end
function M.le(a, b)
  return compareOp("le", a, b)
end
function M.gt(a, b)
  return compareOp("gt", a, b)
end
function M.ge(a, b)
  return compareOp("ge", a, b)
end

function M.flag(flag)
  return cond("flag", { id = flag })
end

function M.not_(condition)
  return cond("not", { operand = condition })
end

function M.all(conditions)
  return cond("all", { conditions = requireTable(conditions, "conditions") })
end

function M.any(conditions)
  return cond("any", { conditions = requireTable(conditions, "conditions") })
end

function M.exists(actorRef)
  return cond("actor_exists", { ref = actorRef })
end

function M.truthy(v)
  return cond("truthy", { value = v })
end

-- 45.5 Control-flow constructors

function M.noop()
  return op("noop")
end
function M.stop()
  return op("stop")
end
function M.yieldTick()
  return op("yield_tick")
end

function M.waitTicks(ticks, opts)
  local spec = asSpec(ticks, { "ticks" })
  if spec then
    return op("wait_ticks", spec)
  end
  local given = { ticks = requireInteger(ticks, "ticks") }
  if opts ~= nil and opts.countdownVariable ~= nil then
    given.countdownVariable = opts.countdownVariable
  end
  return op("wait_ticks", given)
end

function M.if_(spec)
  requireTable(spec, "if spec")
  return op("if", spec)
end

function M.switch(spec)
  requireTable(spec, "switch spec")
  return op("switch", spec)
end

function M.call(scriptId, opts)
  local spec = asSpec(scriptId)
  if spec then
    return op("call", spec)
  end
  local given = { target = requireString(scriptId, "call target") }
  extend(given, opts)
  return op("call", given)
end

function M.callCommon(scriptId, opts)
  local spec = asSpec(scriptId)
  if spec then
    return op("call_common", spec)
  end
  local given = { target = requireString(scriptId, "call_common target") }
  extend(given, opts)
  return op("call_common", given)
end

function M.return_(v)
  local spec = asSpec(v, { "provenance" })
  if spec then
    return op("return", spec)
  end
  local given = {}
  if v ~= nil then
    given.value = v
  end
  return op("return", given)
end

function M.label(name)
  local spec = asSpec(name)
  if spec then
    return op("label", spec)
  end
  return op("label", { name = requireString(name, "label name") })
end

function M.goto_(name)
  local spec = asSpec(name)
  if spec then
    return op("goto", spec)
  end
  return op("goto", { target = requireString(name, "goto target") })
end

function M.gotoIf(condition, name)
  local spec = asSpec(condition, { "target" })
  if spec then
    return op("goto_if", spec)
  end
  return op("goto_if", { condition = condition, target = requireString(name, "goto_if target") })
end

function M.gotoScript(scriptId, opts)
  local spec = asSpec(scriptId)
  if spec then
    return op("goto_script", spec)
  end
  local given = { script = requireString(scriptId, "goto_script target") }
  if opts ~= nil then
    requireTable(opts, "gotoScript opts")
    if opts.label ~= nil then
      given.label = requireString(opts.label, "goto_script label")
    end
  end
  return op("goto_script", given)
end

function M.compare(a, b)
  local spec = asSpec(a, { "left" })
  if spec then
    return op("compare", spec)
  end
  return op("compare", { left = a, right = b })
end

function M.gotoCompared(operator, name, opts)
  local spec = asSpec(operator)
  if spec then
    return op("goto_compared", spec)
  end
  if name == nil and type(opts) == "table" then
    -- Cross-script compare-state form: resolve the composed target at
    -- runtime, consuming the compare state like the source engine.
    local given = { operator = operator }
    if opts.script ~= nil then
      given.script = requireString(opts.script, "goto_compared script")
    end
    if opts.label ~= nil then
      given.label = requireString(opts.label, "goto_compared label")
    end
    return op("goto_compared", given)
  end
  return op("goto_compared", { operator = operator, target = requireString(name, "goto_compared target") })
end

function M.callCompared(operator, target, opts)
  local spec = asSpec(operator)
  if spec then
    return op("call_compared", spec)
  end
  if target == nil and type(opts) == "table" then
    local given = { operator = operator }
    if opts.script ~= nil then
      given.script = requireString(opts.script, "call_compared script")
    end
    if opts.label ~= nil then
      given.label = requireString(opts.label, "call_compared label")
    end
    return op("call_compared", given)
  end
  return op("call_compared", { operator = operator, target = requireString(target, "call_compared target") })
end

function M.next()
  return op("next")
end

-- 45.6 State constructors

function M.setFlag(flag)
  local spec = asSpec(flag, { "flag" })
  if spec then
    return op("set_flag", spec)
  end
  return op("set_flag", { flag = flag })
end
function M.clearFlag(flag)
  local spec = asSpec(flag, { "flag" })
  if spec then
    return op("clear_flag", spec)
  end
  return op("clear_flag", { flag = flag })
end
function M.setVar(id, v)
  local spec = asSpec(id, { "variable" })
  if spec then
    return op("set_var", spec)
  end
  return op("set_var", { variable = id, value = v })
end
function M.copyVar(dst, src)
  local spec = asSpec(dst, { "destination" })
  if spec then
    return op("copy_var", spec)
  end
  return op("copy_var", { destination = dst, source = src })
end
function M.addVar(id, amount)
  local spec = asSpec(id, { "variable" })
  if spec then
    return op("add_var", spec)
  end
  return op("add_var", { variable = id, amount = amount })
end
function M.subVar(id, amount)
  local spec = asSpec(id, { "variable" })
  if spec then
    return op("sub_var", spec)
  end
  return op("sub_var", { variable = id, amount = amount })
end
function M.setLocal(name, v)
  local spec = asSpec(name)
  if spec then
    return op("set_local", spec)
  end
  return op("set_local", { name = name, value = v })
end
function M.copyLocal(dst, src)
  local spec = asSpec(dst)
  if spec then
    return op("copy_local", spec)
  end
  return op("copy_local", { destination = dst, source = src })
end
function M.addLocal(name, amount)
  local spec = asSpec(name)
  if spec then
    return op("add_local", spec)
  end
  return op("add_local", { name = name, amount = amount })
end
function M.subLocal(name, amount)
  local spec = asSpec(name)
  if spec then
    return op("sub_local", spec)
  end
  return op("sub_local", { name = name, amount = amount })
end

-- 45.7 Dialogue constructors

function M.say(message, opts)
  local spec = asSpec(message, { "style", "wait", "close", "timingProfile", "bindings", "provenance" })
  if spec == nil and type(message) == "table" and not looksLikeRef(message) and message.message ~= nil then
    spec = message
  end
  if spec then
    return op("say", spec)
  end
  local given = { message = message }
  extend(given, opts)
  return op("say", given)
end

function M.openMessage(opts)
  return op("open_message", opts)
end

function M.message(message, opts)
  local spec = asSpec(message, { "style", "waitForPrint", "bindings", "provenance" })
  if spec == nil and type(message) == "table" and not looksLikeRef(message) and message.message ~= nil then
    spec = message
  end
  if spec then
    return op("message", spec)
  end
  local given = { message = message }
  extend(given, opts)
  return op("message", given)
end

function M.waitInput(opts)
  return op("wait_input", opts)
end

function M.waitInputOrTicks(opts)
  requireTable(opts, "waitInputOrTicks spec")
  return op("wait_input_or_ticks", opts)
end

function M.closeMessage(opts)
  return op("close_message", opts)
end

function M.holdMessage()
  return op("hold_message")
end

function M.askYesNo(message, opts)
  local spec = asSpec(message, { "result", "bindings", "provenance" })
  if spec == nil and type(message) == "table" and not looksLikeRef(message) and message.message ~= nil then
    spec = message
  end
  if spec then
    return op("ask_yes_no", spec)
  end
  local given = {}
  if message ~= nil then
    given.message = message
  end
  extend(given, opts)
  return op("ask_yes_no", given)
end

function M.bufferText(slot, v)
  local spec = asSpec(slot, { "slot" })
  if spec then
    return op("buffer_text", spec)
  end
  return op("buffer_text", { slot = requireInteger(slot, "buffer slot"), value = v })
end

function M.showWaitingIcon()
  return op("show_waiting_icon")
end
function M.hideWaitingIcon()
  return op("hide_waiting_icon")
end

function M.resolveCommonMessageBank(spec)
  requireTable(spec, "resolveCommonMessageBank spec")
  return op("resolve_common_message_bank", spec)
end

-- 45.8 Lock and actor constructors

function M.lockPlayer()
  return op("lock_player")
end
function M.releasePlayer()
  return op("release_player")
end
function M.lockAll()
  return op("lock_all")
end
function M.releaseAll()
  return op("release_all")
end

function M.lockActor(actor, opts)
  local spec = asSpec(actor, { "actor", "waitUntilPausable", "provenance" })
  if spec then
    return op("lock_actor", spec)
  end
  local given = { actor = actor }
  extend(given, opts)
  return op("lock_actor", given)
end

function M.releaseActor(actor)
  local spec = asSpec(actor, { "actor" })
  if spec then
    return op("release_actor", spec)
  end
  return op("release_actor", { actor = actor })
end

function M.facePlayer(actor)
  local spec = asSpec(actor)
  if spec then
    return op("face_player", spec)
  end
  local given = {}
  if actor ~= nil then
    given.actor = actor
  end
  return op("face_player", given)
end

function M.face(actor, direction)
  local spec = asSpec(actor, { "actor", "direction" })
  if spec then
    return op("face", spec)
  end
  return op("face", { actor = actor, direction = requireDirection(direction) })
end

function M.showObject(actor)
  local spec = asSpec(actor, { "actor" })
  if spec then
    return op("show_object", spec)
  end
  return op("show_object", { actor = actor })
end
function M.hideObject(actor)
  local spec = asSpec(actor, { "actor" })
  if spec then
    return op("hide_object", spec)
  end
  return op("hide_object", { actor = actor })
end

function M.setObjectPosition(actor, position)
  local spec = asSpec(actor, { "fieldX", "fieldZ", "worldY" })
  if spec then
    return op("set_object_position", spec)
  end
  requireTable(position, "position")
  return op("set_object_position", extend({ actor = actor }, position))
end

function M.setObjectFacing(actor, direction)
  local spec = asSpec(actor, { "actor", "direction" })
  if spec then
    return op("set_object_facing", spec)
  end
  return op("set_object_facing", { actor = actor, direction = requireDirection(direction) })
end

function M.setObjectMovementType(actor, movementType)
  local spec = asSpec(actor, { "actor", "movementType" })
  if spec then
    return op("set_object_movement_type", spec)
  end
  return op("set_object_movement_type", { actor = actor, movementType = movementType })
end

function M.getPlayerCoords(spec)
  requireTable(spec, "getPlayerCoords spec")
  return op("get_player_coords", spec)
end

function M.getObjectCoords(actor, spec)
  local asSpecTable = asSpec(actor, { "actor", "x", "z" })
  if asSpecTable then
    return op("get_object_coords", asSpecTable)
  end
  requireTable(spec, "getObjectCoords spec")
  return op("get_object_coords", extend({ actor = actor }, spec))
end

function M.getPlayerFacing(spec)
  requireTable(spec, "getPlayerFacing spec")
  return op("get_player_facing", spec)
end

-- 45.9 Movement constructors

function M.applyMovement(actor, sequence, opts)
  local spec = asSpec(actor, { "actor", "movement", "movementId" })
  if spec then
    return op("apply_movement", spec)
  end
  requireTable(sequence, "movement sequence")
  local given = { actor = actor, movement = sequence }
  extend(given, opts)
  return op("apply_movement", given)
end

function M.waitMovement(opts)
  return op("wait_movement", opts)
end

function M.move(actor, sequence, opts)
  local spec = asSpec(actor, { "actor", "movement", "movementId" })
  if spec then
    return op("move", spec)
  end
  requireTable(sequence, "movement sequence")
  local given = { actor = actor, movement = sequence }
  extend(given, opts)
  return op("move", given)
end

M.m = {}

function M.m.face(direction, count)
  local given = { direction = requireDirection(direction) }
  if count ~= nil then
    given.count = count
  end
  return action("face", given)
end

function M.m.walk(direction, opts)
  local given = { direction = requireDirection(direction) }
  extend(given, opts)
  return action("walk", given)
end

function M.m.walkInPlace(direction, opts)
  local given = { direction = requireDirection(direction) }
  extend(given, opts)
  return action("walk_in_place", given)
end

function M.m.jump(direction, opts)
  local given = { direction = requireDirection(direction) }
  extend(given, opts)
  return action("jump", given)
end

function M.m.delay(ticks, count)
  local given = { ticks = requireInteger(ticks, "delay ticks") }
  if count ~= nil then
    given.count = count
  end
  return action("delay", given)
end

function M.m.setVisible(visible)
  return action("set_visible", { visible = visible })
end

function M.m.lockFacing()
  return action("lock_facing")
end
function M.m.unlockFacing()
  return action("unlock_facing")
end
function M.m.pauseAnimation()
  return action("pause_animation")
end
function M.m.resumeAnimation()
  return action("resume_animation")
end

function M.m.emote(name, count)
  local given = { name = name }
  if count ~= nil then
    given.count = count
  end
  return action("emote", given)
end

function M.m.gesture(name, count)
  local given = { name = name }
  if count ~= nil then
    given.count = count
  end
  return action("gesture", given)
end

function M.m.unsupported(spec)
  requireTable(spec, "unsupported movement spec")
  return action("unsupported", spec)
end

-- 45.10 Audio constructors

function M.playSound(id)
  local spec = asSpec(id)
  if spec then
    return op("play_sound", spec)
  end
  return op("play_sound", { sound = requireString(id, "sound id") })
end

function M.stopSound(id)
  local spec = asSpec(id)
  if spec then
    return op("stop_sound", spec)
  end
  return op("stop_sound", { sound = requireString(id, "sound id") })
end

function M.waitSound(id)
  local spec = asSpec(id)
  if spec then
    return op("wait_sound", spec)
  end
  local given = {}
  if id ~= nil then
    given.sound = requireString(id, "sound id")
  end
  return op("wait_sound", given)
end

function M.playCry(species, opts)
  local spec = asSpec(species, { "species", "form" })
  if spec then
    return op("play_cry", spec)
  end
  local given = { species = species }
  extend(given, opts)
  return op("play_cry", given)
end

function M.waitCry()
  return op("wait_cry")
end

function M.playFanfare(id)
  local spec = asSpec(id)
  if spec then
    return op("play_fanfare", spec)
  end
  return op("play_fanfare", { fanfare = requireString(id, "fanfare id") })
end

function M.waitFanfare()
  return op("wait_fanfare")
end

function M.playMusic(id)
  local spec = asSpec(id)
  if spec then
    return op("play_music", spec)
  end
  return op("play_music", { music = requireString(id, "music id") })
end

function M.stopMusic(id)
  local spec = asSpec(id)
  if spec then
    return op("stop_music", spec)
  end
  local given = {}
  if id ~= nil then
    given.music = requireString(id, "music id")
  end
  return op("stop_music", given)
end

function M.resetMusic()
  return op("reset_music")
end

function M.temporaryMusic(id)
  local spec = asSpec(id)
  if spec then
    return op("temporary_music", spec)
  end
  return op("temporary_music", { music = requireString(id, "music id") })
end

function M.fadeMusicOut(spec)
  requireTable(spec, "fadeMusicOut spec")
  return op("fade_music_out", spec)
end

function M.fadeMusicIn(spec)
  requireTable(spec, "fadeMusicIn spec")
  return op("fade_music_in", spec)
end

-- 45.11 Screen, camera, and map constructors

function M.fadeScreen(spec)
  requireTable(spec, "fadeScreen spec")
  return op("fade_screen", spec)
end

function M.waitFade()
  return op("wait_fade")
end

function M.warp(spec)
  requireTable(spec, "warp spec")
  return op("warp", spec)
end

function M.setSpawn(spawn)
  local spec = asSpec(spawn)
  if spec then
    return op("set_spawn", spec)
  end
  return op("set_spawn", { spawn = requireString(spawn, "spawn id") })
end

function M.shakeCamera(spec)
  requireTable(spec, "shakeCamera spec")
  return op("shake_camera", spec)
end

-- 45.12 Random, raw, and diagnostic constructors

function M.random(spec)
  requireTable(spec, "random spec")
  return op("random", spec)
end

function M.lua(spec)
  requireTable(spec, "lua spec")
  return op("lua", spec)
end

function M.unsupported(spec)
  requireTable(spec, "unsupported spec")
  return op("unsupported", spec)
end

return M
