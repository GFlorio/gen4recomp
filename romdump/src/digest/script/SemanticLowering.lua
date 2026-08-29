-- Semantic lowering : classifies every raw
-- instruction from the pinned implementations and folds supported opcodes
-- into DSL steps with attached provenance. Execution classifications
-- (continue_same_tick / yield_next_tick / native_wait / stop / unsupported)
-- come from the command catalog; folding (Compare+GoToIf -> condition,
-- NPCMsg+WaitButton+CloseMsg -> say) never erases an unmodeled yield
-- boundary. Every instruction keeps source offsets and opcodes in
-- provenance. Pure domain module: no love dependency.

local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")
local MovementDecoder = require("romdump.src.digest.script.MovementDecoder")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local SignpostCommands = require("romdump.src.reference.hgss.signpost_commands")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

local SemanticLowering = {}

-- HGSS GoToIf condition codes.
local CONDITION_OPERATORS = { [0] = "lt", [1] = "eq", [2] = "gt", [3] = "le", [4] = "ge", [5] = "ne" }

-- Numeric direction codes (field movement direction table).
local DIRECTION_BY_CODE = { [0] = "north", [1] = "south", [2] = "west", [3] = "east" }

-- Normalize a numeric direction code to the DSL enum; non-numeric values
-- (symbolic operands) pass through. An unknown numeric code is a lowering
-- fault, never a silent default.
---@param value any
---@return any
local function normalizeFacing(value)
  if type(value) ~= "number" then
    return value
  end
  local direction = DIRECTION_BY_CODE[value]
  assert(direction ~= nil, "unknown direction code " .. tostring(value))
  return direction
end

-- Message symbol -> public message ref: msg_0542_T20_00009 ->
-- "msg.hgss.0542.00009" (bank from the symbol, index from the tail).
---@param symbol string
---@return string
local function messageRef(symbol)
  if type(symbol) ~= "string" then
    return symbol
  end
  local bank, index = symbol:match("^msg_(%d+)_%w+_(%d+)$")
  if bank == nil then
    return symbol
  end
  return string.format("msg.hgss.%04d.%05d", tonumber(bank), tonumber(index))
end

-- A variable-typed operand: symbols stay symbolic, numbers stay numbers.
---@param value any
---@return any
local function operandValue(value)
  if type(value) == "table" then
    return value.raw
  end
  return value
end

-- Value-or-variable operand (ScriptGetVar semantics): an operand is a
-- variable slot when its number lies in the pinned var ranges (vars.h:
-- VARS [0x4000, 0x4400), SPECIAL_VARS [0x8000, 0x8100)) or its symbol
-- carries the VAR_ prefix; anything else is a literal.
---@param value any
---@return any
local function varRef(value)
  local raw = operandValue(value)
  if type(raw) == "number" then
    if (raw >= 0x4000 and raw < 0x4400) or (raw >= 0x8000 and raw < 0x8100) then
      return { value = "var", id = raw }
    end
    return raw
  end
  if raw:match("^VAR_") or raw:match("^SPECIAL_VAR_") then
    return { value = "var", id = raw }
  end
  return raw
end

-- Actor operand: obj_* symbols become actor ids; obj_player and the pinned
-- numeric specials (scrcmd.h: obj_player=255, obj_partner_poke=253; id 0xF1
-- is the field camera target) become specials.
-- Any other numeric id is a local map-object index resolved against the
-- current map at runtime (the pinned MapObjectManager_GetFirstActiveObjectByID
-- path in sub_02041C70).
local STRING_SPECIALS = { obj_player = "player", obj_partner_poke = "partner" }
local NUMERIC_SPECIALS = {
  [255] = "player",
  [253] = "partner",
  [241] = "camera_target",
}

---@param value any
---@return any
local function actorRef(value)
  local raw = operandValue(value)
  local special
  if type(raw) == "number" then
    special = NUMERIC_SPECIALS[raw]
  elseif type(raw) == "string" then
    special = STRING_SPECIALS[raw]
  end
  if special ~= nil then
    return { ref = "actor", special = special }
  end
  if type(raw) == "string" then
    return { ref = "actor", id = raw }
  end
  return { ref = "actor", mapIndex = raw }
end

-- An explicit unsupported node for one instruction.
---@param ins table
---@param reason string
---@return table
local function unsupportedStep(ins, reason)
  local arguments = {}
  for index, operand in ipairs(ins.operands) do
    arguments[index] = operandValue(operand)
  end
  return {
    op = "unsupported",
    command = ins.opcode,
    originalName = CommandCatalog.name(ins.opcode),
    arguments = arguments,
    sourceOffset = ins.offset,
    reason = reason,
  }
end

-- One step with provenance.
---@param step table
---@param offsets integer[]
---@param opcodes integer[]
---@return table
local function withProvenance(step, offsets, opcodes)
  step.provenance = { offsets = offsets, opcodes = opcodes }
  return step
end

-- Movement actions for an ApplyMovement operand.
---@param movementLabel string
---@param memberIr table
---@param _ table
---@return table[] actions, boolean complete, table|nil unsupported
local function movementFor(movementLabel, memberIr, _)
  local offset = tonumber(movementLabel:sub(2), 16)
  local block = memberIr.movements[offset]
  if block == nil then
    return { { action = "unsupported", code = 0, count = 0, originalName = movementLabel } },
      false,
      { code = 0, originalName = movementLabel, reason = "movement block not found" }
  end
  local actions = {}
  local unsupported = nil
  for _, action in ipairs(block.actions) do
    local decoded, err = MovementDecoder.decode(action)
    if err ~= nil then
      if unsupported == nil then
        unsupported = err
      end
      actions[#actions + 1] = {
        action = "unsupported",
        code = action.movementCode or 0,
        count = action.count,
        originalName = action.name,
      }
    else
      actions[#actions + 1] = decoded
    end
  end
  return actions, unsupported == nil, unsupported
end

-- The per-opcode lowering handlers: (instruction, memberIr, provenance) ->
-- step table or nil (op skipped, e.g. Nop), or the string "unfolded" when
-- the instruction participates in a multi-instruction fold handled by the
-- walker (wait_button / close_msg are consumed by the say fold).
local HANDLERS = {
  [609] = function()
    return { op = "yield_tick" }
  end, -- no-follower path of ScrCmd_609
  -- The source special-spawn setter: records the map/coordinates/direction
  -- of a pending special spawn point. Not a query -- it must not vanish as a
  -- noop. warpId -1 and south facing are the source constants (scrcmd_c.c).
  [582] = function(ins)
    return {
      op = "set_special_spawn",
      map = varRef(ins.operands[1]),
      fieldX = varRef(ins.operands[2]),
      fieldZ = varRef(ins.operands[3]),
      warpId = -1,
      direction = "south",
    }
  end,
  -- The follower-active query: the opening no-follower composition has no
  -- following Pokemon, so the source result is always false/0.
  [729] = function(ins)
    return { op = "set_var", variable = varRef(ins.operands[1]), value = 0 }
  end,
  [294] = function(ins)
    -- ScrCmd_CheckBadge: no gym-badge subsystem is implemented, so every
    -- badge check in the fresh-game opening window is source-correctly
    -- false (pret/pokeheartgold src/scrcmd_17.c ScrCmd_CheckBadge /
    -- PlayerProfile_TestBadgeFlag), the same explicit-result pattern as
    -- opcode 729's no-follower query. The badge-index operand only selects
    -- which always-absent badge is being asked about.
    return { op = "set_var", variable = varRef(ins.operands[2]), value = 0 }
  end,
  [0] = function()
    return nil
  end, -- Nop
  [1] = function()
    return nil
  end, -- Dummy
  [2] = function()
    return { op = "stop" }
  end,
  [3] = function(ins, _, _, _)
    -- Wait frames, var: every Wait mirrors the countdown into its
    -- destination variable exactly like the source engine (ScrCmd_Wait
    -- writes the frame count at execution; RunPauseTimer decrements the
    -- variable itself per poll and completes at zero). Nothing is ever
    -- discarded, so observable reads and cross-context reads see the live
    -- countdown. A Wait without a variable operand stays internal to the
    -- task state.
    local step = {
      op = "wait_ticks",
      ticks = operandValue(ins.operands[1]),
    }
    local countdown = varRef(ins.operands[2])
    if type(countdown) == "table" then
      step.countdownVariable = countdown
    end
    return step
  end,
  [17] = function(ins)
    return { op = "compare", left = varRef(ins.operands[1]), right = varRef(ins.operands[2]) }
  end,
  [18] = function(ins)
    return { op = "compare", left = varRef(ins.operands[1]), right = varRef(ins.operands[2]) }
  end,
  [20] = function(ins, _, _, ctx)
    -- CallStd id: resolve the std catalog to the public `common.<name>` id
    -- (decomp symbols and binary numeric ids both resolve); unknown ids stay
    -- mechanical `common.std_<id>`.
    local id = operandValue(ins.operands[1])
    local target
    if ctx.stdCatalog ~= nil then
      target = SourceCatalog.commonPublicId(ctx.stdCatalog, id)
    elseif type(id) == "number" then
      target = "common.std_" .. tostring(id)
    else
      target = "common.std_" .. tostring(id)
    end
    return { op = "call_common", target = target }
  end,
  [21] = function()
    return { op = "signal_caller" }
  end,
  [22] = function(ins)
    return { op = "goto", target = operandValue(ins.operands[1]) }
  end,
  [26] = function(ins)
    return { op = "call", target = operandValue(ins.operands[1]) }
  end,
  [23] = function(ins)
    return {
      op = "goto_if",
      condition = {
        condition = "compare",
        operator = "eq",
        left = { value = "object_id", ref = { ref = "actor", special = "self" } },
        right = operandValue(ins.operands[1]),
      },
      target = operandValue(ins.operands[2]),
    }
  end,
  [24] = function(ins)
    return {
      op = "goto_if",
      condition = {
        condition = "compare",
        operator = "eq",
        left = { value = "trigger_background_id" },
        right = operandValue(ins.operands[1]),
      },
      target = operandValue(ins.operands[2]),
    }
  end,
  [25] = function(ins)
    return {
      op = "goto_if",
      condition = {
        condition = "compare",
        operator = "eq",
        left = { value = "trigger_direction" },
        right = operandValue(ins.operands[1]),
      },
      target = operandValue(ins.operands[2]),
    }
  end,
  [27] = function()
    return { op = "return" }
  end,
  [28] = function()
    return "unfolded"
  end, -- folded with the compare/flag
  [29] = function()
    return "unfolded"
  end, -- folded with the compare/flag
  [30] = function(ins)
    return { op = "set_flag", flag = operandValue(ins.operands[1]) }
  end,
  [31] = function(ins)
    return { op = "clear_flag", flag = operandValue(ins.operands[1]) }
  end,
  [32] = function()
    return "unfolded"
  end, -- folded with GoToIfSet/Unset
  [33] = function(ins)
    return { op = "set_flag", flag = varRef(ins.operands[1]) }
  end,
  [34] = function(ins)
    return { op = "clear_flag", flag = varRef(ins.operands[1]) }
  end,
  [35] = function(ins)
    return {
      op = "set_var",
      variable = varRef(ins.operands[2]),
      value = { value = "flag_value", flag = varRef(ins.operands[1]) },
    }
  end,
  [39] = function(ins)
    return { op = "add_var", variable = varRef(ins.operands[1]), amount = varRef(ins.operands[2]) }
  end,
  [40] = function(ins)
    return { op = "sub_var", variable = varRef(ins.operands[1]), amount = varRef(ins.operands[2]) }
  end,
  [41] = function(ins)
    return { op = "set_var", variable = varRef(ins.operands[1]), value = operandValue(ins.operands[2]) }
  end,
  [42] = function(ins)
    return {
      op = "copy_var",
      destination = varRef(ins.operands[1]),
      source = varRef(ins.operands[2]),
    }
  end,
  [43] = function(ins)
    return { op = "set_var", variable = varRef(ins.operands[1]), value = varRef(ins.operands[2]) }
  end,
  [44] = function(ins)
    return {
      op = "message",
      message = messageRef(operandValue(ins.operands[1])),
      waitForPrint = false,
    }
  end,
  [45] = function(ins)
    return { op = "npc_msg", message = messageRef(operandValue(ins.operands[1])) }
  end,
  [46] = function(ins)
    return {
      op = "message",
      message = varRef(ins.operands[1]),
      waitForPrint = false,
    }
  end,
  [47] = function(ins)
    return { op = "npc_msg_var", message = varRef(ins.operands[1]) }
  end,
  [49] = function()
    return { op = "wait_input", buttons = { "a", "b" } }
  end,
  [50] = function()
    return { op = "wait_input", buttons = { "a", "b" }, allowDpad = true, turnPlayerOnDpad = true }
  end,
  [51] = function()
    return { op = "wait_input", buttons = { "a", "b" }, allowDpad = true, turnPlayerOnDpad = false }
  end,
  [52] = function()
    return { op = "open_message" }
  end,
  [53] = function()
    return "unfolded"
  end, -- consumed by the say fold
  [54] = function()
    return { op = "hold_message" }
  end,
  [55] = function(ins, memberIr)
    -- DirectionSignpost message, type, map: the source handler never reads
    -- or writes the final operand (audited unused), so it is erased here —
    -- the raw decoded instruction operands keep it for source auditing, the
    -- semantic node does not. The message id is a direct index into the
    -- member's message bank (the decoder does not bank-resolve 55); the
    -- runtime resolves it.
    assert(memberIr.messageBank ~= nil, "direction signpost requires a script message bank")
    return {
      op = "signpost_direction",
      message = { message = "external", bank = memberIr.messageBank, id = operandValue(ins.operands[1]) },
      sourceAppearance = {
        game = "hgss",
        type = operandValue(ins.operands[2]),
        map = operandValue(ins.operands[3]),
      },
    }
  end,
  [56] = function(ins)
    -- SetSignpostMap type, map: writes the source appearance and queues
    -- SHOW without executing it (the field signpost update runs it later).
    return {
      op = "signpost_set",
      sourceAppearance = {
        game = "hgss",
        type = operandValue(ins.operands[1]),
        map = operandValue(ins.operands[2]),
      },
    }
  end,
  [57] = function(ins)
    -- SetSignpostAction command: the raw MAPSIGNCOMMAND_* code 0..4 lowers
    -- to the semantic command enum (nop/show/wipe_out/wipe_in/hide). An
    -- unknown code is malformed source and never defaults to nop.
    local raw = operandValue(ins.operands[1])
    local command = SignpostCommands.semanticName(raw)
    assert(command ~= nil, "unknown signpost command code " .. tostring(raw))
    return { op = "signpost_command", command = command }
  end,
  [58] = function()
    -- WaitSignpostAction: blocks until the command returns to nop; the
    -- runtime wait task polls the signpost host's command.
    return { op = "wait_signpost_action" }
  end,
  [59] = function(ins, memberIr)
    -- TrainerTips message, resultVar: prints into the existing signpost
    -- window at the player's text speed. The message id is a direct index
    -- into the member's message bank (the decoder does not bank-resolve
    -- 59); the runtime resolves it. The result var rides the task result.
    assert(memberIr.messageBank ~= nil, "trainer tips requires a script message bank")
    return {
      op = "trainer_tips_print",
      message = { message = "external", bank = memberIr.messageBank, id = operandValue(ins.operands[1]) },
      result = varRef(ins.operands[2]),
    }
  end,
  [60] = function(ins)
    -- WaitSignpost resultVar: waits for A/B/directional dismissal of the
    -- presented signpost window; the result var rides the task result.
    return {
      op = "wait_signpost",
      result = varRef(ins.operands[1]),
    }
  end,
  [61] = function()
    -- ScrCmd_061 (std_signpost's hide-branch tail): no operands; installs
    -- the Start Menu reopen end callback and returns FALSE, ending the
    -- script context. The runtime request_start_menu handler routes the
    -- reopen request through the startMenuReopen service and stops.
    return { op = "request_start_menu" }
  end,
  [63] = function(ins)
    return { op = "ask_yes_no", result = varRef(ins.operands[1] or 0) }
  end,
  [73] = function(ins)
    -- PlaySE reads its operand through ScriptGetVar (scrcmd_sound.c).
    return { op = "play_sound", sound = varRef(ins.operands[1]) }
  end,
  [74] = function(ins)
    return { op = "stop_sound", sound = varRef(ins.operands[1]) }
  end,
  [75] = function(ins)
    return { op = "wait_sound", sound = varRef(ins.operands[1]) }
  end,
  [76] = function(ins)
    -- PlayCryEx reads both operands through ScriptGetVar (scrcmd_sound.c).
    return { op = "play_cry", species = varRef(ins.operands[1]), form = varRef(ins.operands[2]) }
  end,
  [77] = function()
    return { op = "wait_cry" }
  end,
  [78] = function(ins)
    return { op = "play_fanfare", fanfare = varRef(ins.operands[1]) }
  end,
  [79] = function()
    return { op = "wait_fanfare" }
  end,
  [80] = function(ins)
    return { op = "play_music", music = operandValue(ins.operands[1]) }
  end,
  [81] = function()
    -- The pinned ScrCmd_StopBGM ignores its operand entirely (it stops the
    -- currently playing BGM), so the operand is a documented erasure.
    return { op = "stop_music" }
  end,
  [82] = function()
    return { op = "reset_music" }
  end,
  [84] = function(ins)
    return {
      op = "fade_music_out",
      target = operandValue(ins.operands[1]),
      durationTicks = operandValue(ins.operands[2]),
    }
  end,
  [85] = function(ins)
    return { op = "fade_music_in", durationTicks = operandValue(ins.operands[1]) }
  end,
  [87] = function(ins)
    return { op = "temporary_music", music = operandValue(ins.operands[1]) }
  end,
  [94] = function(ins, memberIr, provenance)
    local movementLabel = operandValue(ins.operands[2])
    local actions, complete, unsupported = movementFor(movementLabel, memberIr, provenance)
    return {
      op = "apply_movement",
      actor = actorRef(ins.operands[1]),
      movement = actions,
      movementComplete = complete,
      movementUnsupported = unsupported,
    }
  end,
  [95] = function()
    return { op = "wait_movement" }
  end,
  [96] = function()
    return { op = "lock_all" }
  end,
  [97] = function()
    return { op = "release_all" }
  end,
  [98] = function(ins)
    return { op = "lock_actor", actor = actorRef(ins.operands[1]) }
  end,
  [99] = function(ins)
    return { op = "release_actor", actor = actorRef(ins.operands[1]) }
  end,
  [100] = function(ins)
    return { op = "show_object", actor = actorRef(ins.operands[1]) }
  end,
  [101] = function(ins)
    return { op = "hide_object", actor = actorRef(ins.operands[1]) }
  end,
  [104] = function()
    return { op = "face_player" }
  end,
  [105] = function(ins)
    return {
      op = "get_player_coords",
      x = varRef(ins.operands[1]),
      z = varRef(ins.operands[2]),
    }
  end,
  [106] = function(ins)
    return {
      op = "get_object_coords",
      actor = actorRef(ins.operands[1]),
      x = varRef(ins.operands[2]),
      z = varRef(ins.operands[3]),
    }
  end,
  [144] = function(ins)
    -- ScrCmd_GetFriendSprite: the opening friend NPC's sprite is always the
    -- gender opposite the player's own; no follower subsystem is involved.
    return { op = "set_var", variable = varRef(ins.operands[1]), value = { value = "friend_sprite_value" } }
  end,
  [132] = function(ins)
    return {
      op = "npc_msg",
      message = {
        text = "gendered_message",
        male = messageRef(operandValue(ins.operands[1])),
        female = messageRef(operandValue(ins.operands[2])),
      },
    }
  end,
  [174] = function(ins)
    local rawType = operandValue(ins.operands[3])
    local direction
    if rawType == 0 then
      direction = "out"
    elseif rawType == 1 then
      direction = "in"
    else
      assert(false, "unknown fade type " .. tostring(rawType))
    end
    local rawColor = operandValue(ins.operands[4])
    local color
    if rawColor == 0 then
      color = "black"
    elseif rawColor == 0x7FFF or rawColor == 32767 then
      color = "white"
    else
      assert(false, "unknown fade color " .. tostring(rawColor))
    end
    return {
      op = "fade_screen",
      duration = operandValue(ins.operands[1]),
      speed = operandValue(ins.operands[2]),
      direction = direction,
      color = color,
    }
  end,
  [175] = function()
    return { op = "wait_fade" }
  end,
  [176] = function(ins)
    -- Warp map, warp, x, z, dir: coordinates and direction may be variable
    -- operands; numeric directions normalize to the string enum.
    return {
      op = "warp",
      map = varRef(ins.operands[1]),
      warp = varRef(ins.operands[2]),
      fieldX = varRef(ins.operands[3]),
      fieldZ = varRef(ins.operands[4]),
      facing = normalizeFacing(operandValue(ins.operands[5])),
    }
  end,
  [190] = function(ins)
    return { op = "buffer_text", slot = operandValue(ins.operands[1]), value = { text = "player_name" } }
  end,
  [191] = function(ins)
    return { op = "buffer_text", slot = operandValue(ins.operands[1]), value = { text = "rival_name" } }
  end,
  [192] = function(ins)
    return { op = "buffer_text", slot = operandValue(ins.operands[1]), value = { text = "friend_name" } }
  end,
  [193] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "party_species_name", position = operandValue(ins.operands[2]) },
    }
  end,
  [194] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "item_name", value = varRef(ins.operands[2]) },
    }
  end,
  [195] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "pocket_name", value = varRef(ins.operands[2]) },
    }
  end,
  [196] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "tmhm_move_name", value = varRef(ins.operands[2]) },
    }
  end,
  [197] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "move_name", value = varRef(ins.operands[2]) },
    }
  end,
  [198] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "integer", value = varRef(ins.operands[2]) },
    }
  end,
  [199] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "party_nickname", position = operandValue(ins.operands[2]) },
    }
  end,
  [200] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "trainer_class_name", value = varRef(ins.operands[2]) },
    }
  end,
  [202] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "species_name", value = operandValue(ins.operands[2]) },
    }
  end,
  [203] = function(ins)
    return { op = "buffer_text", slot = operandValue(ins.operands[1]), value = { text = "starter_species_name" } }
  end,
  [210] = function(ins)
    return {
      op = "buffer_text",
      slot = operandValue(ins.operands[1]),
      value = { text = "map_name", value = operandValue(ins.operands[2]) },
    }
  end,
  [280] = function(ins)
    return { op = "set_spawn", spawn = operandValue(ins.operands[1]) }
  end,
  [281] = function(ins)
    return { op = "set_var", variable = varRef(ins.operands[1]), value = { value = "player_gender_value" } }
  end,
  [338] = function(ins)
    return {
      op = "set_object_position",
      actor = actorRef(ins.operands[1]),
      fieldX = varRef(ins.operands[2]),
      fieldZ = varRef(ins.operands[3]),
    }
  end,
  [339] = function(ins)
    -- ScrCmd_MovePersonFacing (src/scrcmd_c.c) reads objectId, x, y, z,
    -- direction: the ground-plane Z is the fourth operand and height is the
    -- third, even though the assembly macro's own parameter names read
    -- "x, z, y". Field X from the second operand, world Y (height) from the
    -- third, field Z from the fourth, then face the given direction (two
    -- canonical operations; the facing side effect is never diagnostic
    -- data).
    local actor = actorRef(ins.operands[1])
    return {
      steps = {
        {
          op = "set_object_position",
          actor = actor,
          fieldX = varRef(ins.operands[2]),
          worldY = varRef(ins.operands[3]),
          fieldZ = varRef(ins.operands[4]),
        },
        {
          op = "set_object_facing",
          actor = actor,
          direction = normalizeFacing(operandValue(ins.operands[5])),
        },
      },
    }
  end,
  [340] = function(ins)
    return {
      op = "set_object_movement_type",
      actor = actorRef(ins.operands[1]),
      movementType = tostring(operandValue(ins.operands[2])),
    }
  end,
  [341] = function(ins)
    return {
      op = "set_object_facing",
      actor = actorRef(ins.operands[1]),
      direction = normalizeFacing(operandValue(ins.operands[2])),
    }
  end,
  [345] = function()
    return { op = "show_waiting_icon" }
  end,
  [346] = function()
    return { op = "hide_waiting_icon" }
  end,
  [348] = function(ins)
    return { op = "wait_input_or_ticks", ticks = operandValue(ins.operands[1]) }
  end,
  [375] = function(ins)
    return { op = "show_object", actor = actorRef(ins.operands[1]) }
  end,
  [380] = function(ins)
    -- Random arg0, arg1: arg0 is the destination variable pointer and arg1
    -- is the modulo source (ScrCmd_Random reads the dest first).
    return { op = "random", result = varRef(ins.operands[1]), maxExclusive = operandValue(ins.operands[2]) }
  end,
  [386] = function(ins)
    return { op = "get_player_facing", result = varRef(ins.operands[1]) }
  end,
  [438] = function()
    return "unfolded"
  end,
  [439] = function(ins)
    return {
      op = "message",
      message = { message = "external", bank = varRef(ins.operands[1]), id = varRef(ins.operands[2]) },
      waitForPrint = false,
    }
  end,
  [440] = function(ins)
    return {
      op = "message",
      message = { message = "external", bank = varRef(ins.operands[1]), id = varRef(ins.operands[2]) },
      waitForPrint = true,
    }
  end,
  [749] = function(ins)
    return {
      op = "menu_begin",
      messageSource = "standard",
      sourcePlacement = {
        system = MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT,
        x = operandValue(ins.operands[1]),
        y = operandValue(ins.operands[2]),
      },
      initialCursor = operandValue(ins.operands[3]),
      cancellable = operandValue(ins.operands[4]) ~= 0,
      result = varRef(ins.operands[5]),
    }
  end,
  [750] = function(ins, memberIr)
    assert(memberIr.messageBank ~= nil, "script menu requires a current script message bank")
    return {
      op = "menu_begin",
      messageSource = { kind = "script", bank = memberIr.messageBank },
      sourcePlacement = {
        system = MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT,
        x = operandValue(ins.operands[1]),
        y = operandValue(ins.operands[2]),
      },
      initialCursor = operandValue(ins.operands[3]),
      cancellable = operandValue(ins.operands[4]) ~= 0,
      result = varRef(ins.operands[5]),
    }
  end,
  [751] = function(ins)
    return {
      op = "menu_add",
      messageId = varRef(ins.operands[1]),
      vanillaMetadata = varRef(ins.operands[2]),
      value = varRef(ins.operands[3]),
    }
  end,
  [752] = function()
    return { op = "menu_exec" }
  end,
  [581] = function(_)
    return { op = "lock_actor", actor = { ref = "actor", special = "last_talked" }, waitUntilPausable = true }
  end,
  [746] = function()
    return { op = "set_auxiliary_ui_visible", visible = false }
  end,
  [747] = function()
    return { op = "set_auxiliary_ui_visible", visible = true }
  end,
  [748] = function(ins)
    return { op = "context_choice", result = varRef(ins.operands[1]) }
  end,
  [726] = function()
    return { op = "process_soundplate" }
  end,
}

-- Fold a compare/flag instruction with a following GoToIf/CallIf into one
-- conditional item, or nil when the pattern does not apply (the compare
-- result is consumed by the immediately following branch).
---@param ins table
---@param branch table
---@return table|nil item
local function foldConditional(ins, branch)
  local conditionCode = operandValue(branch.operands[1])
  local operator = CONDITION_OPERATORS[conditionCode]
  if operator == nil then
    return nil
  end
  local target = operandValue(branch.operands[2])
  local condition
  if ins.opcode == 17 or ins.opcode == 18 then
    condition = {
      condition = "compare",
      operator = operator,
      left = varRef(ins.operands[1]),
      right = varRef(ins.operands[2]),
    }
  elseif ins.opcode == 32 then
    local expected
    if conditionCode == 1 then
      expected = true
    elseif conditionCode == 0 or conditionCode == 5 then
      expected = false
    else
      return nil
    end
    condition = { condition = "flag", id = operandValue(ins.operands[1]), expected = expected }
  else
    return nil
  end
  return {
    op = branch.opcode == 29 and "call_if" or "if_cond",
    condition = condition,
    target = target,
    provenance = {
      offsets = { ins.offset, branch.offset },
      opcodes = { ins.opcode, branch.opcode },
    },
  }
end

-- The NPCMsg + WaitButton + CloseMsg triplet folds into `say` with the hgss
-- timing profile. Returns the say item plus the
-- number of instructions consumed (3), or nil.
---@param messageStep table
---@param waitIns table
---@param closeIns table
---@return table|nil say
local function foldSay(messageStep, waitIns, closeIns)
  if waitIns.opcode ~= 50 then
    return nil
  end
  if closeIns.opcode ~= 53 then
    return nil
  end
  return {
    op = "say",
    message = messageStep.message,
    provenance = {
      offsets = { messageStep.provenance.offsets[1], waitIns.offset, closeIns.offset },
      opcodes = { messageStep.provenance.opcodes[1], waitIns.opcode, closeIns.opcode },
    },
  }
end

-- An unconsumed NPCMsg/GenderMsgBox becomes the primitive `message` op with
-- the native print wait (opcodes 45 and 132).
---@param step table
---@return table
local function toMessageStep(step)
  local message = step.message
  return {
    op = "message",
    message = message,
    waitForPrint = true,
  }
end

-- Lower one script's instruction list into semantic items. `memberIr` holds
-- the movement blocks. Folding never erases an unmodeled yield boundary.
-- `opts.stdCatalog` (SourceCatalog) resolves CallStd targets; without it
-- targets stay mechanical `common.std_<id>`. The returned table carries the
-- `omissions` (Nop/Dummy erasures) for the verifier.
---@param script table
---@param memberIr table
---@param opts table
---@return table lowered
function SemanticLowering.lowerScript(script, memberIr, opts)
  local items = {}
  local unsupported = {}
  local omissions = {}
  local index = 1
  local instructions = script.instructions

  local ctx = {
    stdCatalog = opts.stdCatalog,
  }

  -- Script-local labels: branch and call targets must resolve inside the
  -- script. The pinned sources share tails across scripts: a branch may
  -- jump into another script's label region or into another script's entry.
  -- Such a branch becomes a runtime-resolved cross-script reference
  -- (`goto_script`, or `call` with a label) naming the target script by its
  -- public id, resolved through the composition registry at runtime like
  -- the raw-Lua escape hatch. A target that resolves to no script in the
  -- member stays an explicit unsupported node.
  local scriptLabels = {}
  for _, ins in ipairs(instructions) do
    if ins.label ~= nil then
      scriptLabels[ins.label] = true
    end
  end
  local memberLabels = {}
  local memberBodyLabels = {}
  for memberIndex, memberScript in pairs(memberIr.scripts) do
    memberBodyLabels[memberScript.label] = memberIndex
    for _, ins in ipairs(memberScript.instructions) do
      if ins.label ~= nil then
        memberLabels[ins.label] = memberIndex
      end
    end
  end
  local function publicIdFor(ownerIndex)
    if opts.publicIdFor ~= nil then
      return opts.publicIdFor(memberIr.member, ownerIndex)
    end
    return ScriptIdentity.formatVanilla(memberIr.member, ownerIndex)
  end
  local CONTROL_TARGET_OPS = {
    ["goto"] = true,
    goto_if = true,
    if_cond = true,
    call_if = true,
    call = true,
    goto_compared = true,
    call_compared = true,
  }
  local function resolveControlTargets(list)
    for i, item in ipairs(list) do
      if item.target ~= nil and CONTROL_TARGET_OPS[item.op] then
        local target = item.target
        local owner
        if type(target) == "string" and not scriptLabels[target] then
          owner = memberLabels[target] or memberBodyLabels[target]
        end
        if owner ~= nil then
          local scriptId = publicIdFor(owner)
          local label = memberLabels[target] ~= nil and target or nil
          local provenance = item.provenance
          if item.op == "goto" then
            local step = { op = "goto_script", script = scriptId, provenance = provenance }
            if label ~= nil then
              step.label = label
            end
            list[i] = step
          elseif item.op == "call" then
            local step = { op = "call", target = scriptId, provenance = provenance }
            if label ~= nil then
              step.label = label
            end
            list[i] = step
          elseif item.op == "call_if" then
            list[i] = {
              op = "if",
              condition = item.condition,
              yes = { { op = "call", target = scriptId, label = label } },
              no = {},
              provenance = provenance,
            }
          elseif item.op == "goto_if" or item.op == "if_cond" then
            -- A conditional cross-script jump.
            local jump = { op = "goto_script", script = scriptId }
            if label ~= nil then
              jump.label = label
            end
            list[i] = {
              op = "if",
              condition = item.condition,
              yes = { jump },
              no = {},
              provenance = provenance,
            }
          else
            -- The compare-state fallback forms preserve the source compare
            -- state; a cross-script target rides the same runtime state via
            -- the additive script/label fields.
            local step = {
              op = item.op,
              operator = item.operator,
              script = scriptId,
              provenance = provenance,
            }
            if label ~= nil then
              step.label = label
            end
            list[i] = step
          end
        elseif type(target) ~= "string" or not scriptLabels[target] then
          local provenance = item.provenance
          local branchOffset = provenance and provenance.offsets[#provenance.offsets]
          local branchOpcode = provenance and provenance.opcodes[#provenance.opcodes]
          local step = {
            op = "unsupported",
            command = branchOpcode or 0,
            originalName = CommandCatalog.name(branchOpcode or 0),
            arguments = {},
            sourceOffset = branchOffset or 0,
            reason = "branch target does not exist in this member",
            provenance = provenance,
          }
          list[i] = step
          unsupported[#unsupported + 1] = step
        end
      end
    end
  end

  -- Label markers: the first instruction after an offset label carries it;
  -- the emitted item (or the fold consuming that instruction) receives a
  -- preceding label step so the structurer can resolve branch targets.
  local function pushLabel(ins)
    if ins.label ~= nil then
      items[#items + 1] = { op = "label", name = ins.label, offset = ins.offset }
    end
  end

  while index <= #instructions do
    local ins = instructions[index]
    local nextIns = instructions[index + 1]
    local handler = HANDLERS[ins.opcode]
    local foldedAhead = false

    -- Compare/flag + GoToIf/CallIf fold (both remain same-tick). The fold
    -- never spans a labeled instruction: a branch target landing on the
    -- second instruction must enter at the branch (with the caller's
    -- compare state), not at the folded operation's start.
    if
      handler ~= nil
      and nextIns ~= nil
      and (nextIns.opcode == 28 or nextIns.opcode == 29)
      and (ins.opcode == 17 or ins.opcode == 18 or ins.opcode == 32)
      and nextIns.label == nil
    then
      local folded = foldConditional(ins, nextIns)
      if folded ~= nil then
        pushLabel(ins)
        pushLabel(nextIns)
        items[#items + 1] = folded
        index = index + 1
        foldedAhead = true
      end
    end

    -- NPCMsg/GenderMsgBox + WaitButton + CloseMsg -> say. Same labeled-entry
    -- rule: an entry point on the wait or close instruction keeps the three
    -- instructions separate.
    if
      not foldedAhead
      and handler ~= nil
      and nextIns ~= nil
      and instructions[index + 2] ~= nil
      and (ins.opcode == 45 or ins.opcode == 132 or ins.opcode == 47)
      and nextIns.label == nil
      and instructions[index + 2].label == nil
    then
      local step = handler(ins, memberIr, {}, ctx)
      if type(step) == "table" and (step.op == "npc_msg" or step.op == "npc_msg_var") then
        step = withProvenance(step, { ins.offset }, { ins.opcode })
        local say = foldSay(step, nextIns, instructions[index + 2])
        if say ~= nil then
          pushLabel(ins)
          pushLabel(nextIns)
          pushLabel(instructions[index + 2])
          items[#items + 1] = say
          index = index + 2
          foldedAhead = true
        end
      end
    end

    if foldedAhead then
      -- consumed by a fold
    elseif handler == nil then
      local step = unsupportedStep(ins, "opcode has no semantic lowering")
      step = withProvenance(step, { ins.offset }, { ins.opcode })
      pushLabel(ins)
      items[#items + 1] = step
      unsupported[#unsupported + 1] = step
    elseif not foldedAhead then
      local step = handler(ins, memberIr, { offsets = { ins.offset }, opcodes = { ins.opcode } }, ctx)
      if step == nil then
        -- An explicitly erased implementation-detail instruction (Nop and
        -- Dummy, rows 0-1): record the omission for the
        -- verifier's no-disappearing-command check.
        omissions[#omissions + 1] = { offset = ins.offset, opcode = ins.opcode }
      elseif step == "unfolded" then
        -- An unconsumed fold participant becomes its primitive step.
        local primitive
        if ins.opcode == 53 then
          primitive = { op = "close_message", erase = true }
        elseif ins.opcode == 28 or ins.opcode == 29 then
          local operator = CONDITION_OPERATORS[operandValue(ins.operands[1])] or "eq"
          primitive = {
            op = ins.opcode == 29 and "call_compared" or "goto_compared",
            operator = operator,
            target = operandValue(ins.operands[2]),
          }
        end
        if primitive ~= nil then
          primitive = withProvenance(primitive, { ins.offset }, { ins.opcode })
          pushLabel(ins)
          items[#items + 1] = primitive
        else
          local unsupportedRecord = {
            op = "unsupported",
            command = ins.opcode,
            originalName = CommandCatalog.name(ins.opcode),
            arguments = {},
            sourceOffset = ins.offset,
            reason = "unconsumed compare-state op without a DSL carrier",
          }
          unsupportedRecord = withProvenance(unsupportedRecord, { ins.offset }, { ins.opcode })
          pushLabel(ins)
          items[#items + 1] = unsupportedRecord
          unsupported[#unsupported + 1] = unsupportedRecord
        end
      elseif step ~= nil then
        local handled = false
        if type(step) == "table" and type(step.steps) == "table" then
          -- One instruction lowering to several canonical operations (e.g.
          -- MovePersonFacing: position then facing); all steps share the
          -- instruction's provenance.
          pushLabel(ins)
          for _, subStep in ipairs(step.steps) do
            items[#items + 1] = withProvenance(subStep, { ins.offset }, { ins.opcode })
          end
          handled = true
        elseif step.op == "release_all" then
          -- The source command unconditionally yields one frame after
          -- unpausing. The synthesized yield has
          -- no source instruction of its own, so it carries no provenance
          -- (its node id is structural, avoiding a duplicate with the
          -- release node's src: id).
          pushLabel(ins)
          items[#items + 1] = withProvenance(step, { ins.offset }, { ins.opcode })
          items[#items + 1] = { op = "yield_tick" }
          handled = true
        elseif step.op == "npc_msg" or step.op == "npc_msg_var" then
          step = toMessageStep(step)
        end
        if not handled then
          step = withProvenance(step, { ins.offset }, { ins.opcode })
          pushLabel(ins)
          items[#items + 1] = step
        end
      end
    end
    index = index + 1
  end
  resolveControlTargets(items)
  return { items = items, unsupported = unsupported, omissions = omissions }
end

return SemanticLowering
