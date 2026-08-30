-- Script lowering handlers for field interactions and actor/UI operations.
local Operands = require("romdump.src.digest.script.lowering.Operands")
local MovementDecoder = require("romdump.src.digest.script.MovementDecoder")
local SignpostCommands = require("romdump.src.reference.hgss.signpost_commands")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

-- Field-only operand normalization follows the pinned field direction table,
-- message-symbol format, and scrcmd.h actor specials.
local DIRECTION_BY_CODE = { [0] = "north", [1] = "south", [2] = "west", [3] = "east" }
local STRING_SPECIALS = { obj_player = "player", obj_partner_poke = "partner" }
local NUMERIC_SPECIALS = {
  [255] = "player",
  [253] = "partner",
  [241] = "camera_target",
}

local function normalizeFacing(value)
  if type(value) ~= "number" then
    return value
  end
  local direction = DIRECTION_BY_CODE[value]
  assert(direction ~= nil, "unknown direction code " .. tostring(value))
  return direction
end

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

local function actorRef(value)
  local raw = Operands.operandValue(value)
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

local function nonNpcMessage(ins)
  return {
    op = "message",
    message = messageRef(Operands.operandValue(ins.operands[1])),
    waitForPrint = false,
  }
end

local function npcMessage(ins)
  return { op = "npc_msg", message = messageRef(Operands.operandValue(ins.operands[1])) }
end

local function nonNpcMessageVar(ins)
  return {
    op = "message",
    message = Operands.varRef(ins.operands[1]),
    waitForPrint = false,
  }
end

local function npcMessageVar(ins)
  return { op = "npc_msg_var", message = Operands.varRef(ins.operands[1]) }
end

local function waitInput()
  return { op = "wait_input", buttons = { "a", "b" } }
end

local function waitInputTurn()
  return { op = "wait_input", buttons = { "a", "b" }, allowDpad = true, turnPlayerOnDpad = true }
end

local function waitInputNoTurn()
  return { op = "wait_input", buttons = { "a", "b" }, allowDpad = true, turnPlayerOnDpad = false }
end

local function openMessage()
  return { op = "open_message" }
end

local function closeMessage()
  return "unfolded"
end -- consumed by the say fold

local function holdMessage()
  return { op = "hold_message" }
end

local function directionSignpost(ins, memberIr)
  -- DirectionSignpost message, type, map: the source handler never reads
  -- or writes the final operand (audited unused), so it is erased here —
  -- the raw decoded instruction operands keep it for source auditing, the
  -- semantic node does not. The message id is a direct index into the
  -- member's message bank (the decoder does not bank-resolve 55); the
  -- runtime resolves it.
  assert(memberIr.messageBank ~= nil, "direction signpost requires a script message bank")
  return {
    op = "signpost_direction",
    message = { message = "external", bank = memberIr.messageBank, id = Operands.operandValue(ins.operands[1]) },
    sourceAppearance = {
      game = "hgss",
      type = Operands.operandValue(ins.operands[2]),
      map = Operands.operandValue(ins.operands[3]),
    },
  }
end

local function setSignpostMap(ins)
  -- SetSignpostMap type, map: writes the source appearance and queues
  -- SHOW without executing it (the field signpost update runs it later).
  return {
    op = "signpost_set",
    sourceAppearance = {
      game = "hgss",
      type = Operands.operandValue(ins.operands[1]),
      map = Operands.operandValue(ins.operands[2]),
    },
  }
end

local function setSignpostAction(ins)
  -- SetSignpostAction command: the raw MAPSIGNCOMMAND_* code 0..4 lowers
  -- to the semantic command enum (nop/show/wipe_out/wipe_in/hide). An
  -- unknown code is malformed source and never defaults to nop.
  local raw = Operands.operandValue(ins.operands[1])
  local command = SignpostCommands.semanticName(raw)
  assert(command ~= nil, "unknown signpost command code " .. tostring(raw))
  return { op = "signpost_command", command = command }
end

local function waitSignpostAction()
  -- WaitSignpostAction: blocks until the command returns to nop; the
  -- runtime wait task polls the signpost host's command.
  return { op = "wait_signpost_action" }
end

local function trainerTipsPrint(ins, memberIr)
  -- TrainerTips message, resultVar: prints into the existing signpost
  -- window at the player's text speed. The message id is a direct index
  -- into the member's message bank (the decoder does not bank-resolve
  -- 59); the runtime resolves it. The result var rides the task result.
  assert(memberIr.messageBank ~= nil, "trainer tips requires a script message bank")
  return {
    op = "trainer_tips_print",
    message = { message = "external", bank = memberIr.messageBank, id = Operands.operandValue(ins.operands[1]) },
    result = Operands.varRef(ins.operands[2]),
  }
end

local function waitSignpost(ins)
  -- WaitSignpost resultVar: waits for A/B/directional dismissal of the
  -- presented signpost window; the result var rides the task result.
  return {
    op = "wait_signpost",
    result = Operands.varRef(ins.operands[1]),
  }
end

local function requestStartMenu()
  -- ScrCmd_061 (std_signpost's hide-branch tail): no operands; installs
  -- the Start Menu reopen end callback and returns FALSE, ending the
  -- script context. The runtime request_start_menu handler routes the
  -- reopen request through the startMenuReopen service and stops.
  return { op = "request_start_menu" }
end

local function askYesNo(ins)
  return { op = "ask_yes_no", result = Operands.varRef(ins.operands[1] or 0) }
end

local function applyMovement(ins, memberIr, provenance)
  local movementLabel = Operands.operandValue(ins.operands[2])
  local actions, complete, unsupported = movementFor(movementLabel, memberIr, provenance)
  return {
    op = "apply_movement",
    actor = actorRef(ins.operands[1]),
    movement = actions,
    movementComplete = complete,
    movementUnsupported = unsupported,
  }
end

local function waitMovement()
  return { op = "wait_movement" }
end

local function lockAll()
  return { op = "lock_all" }
end

local function releaseAll()
  return { op = "release_all" }
end

local function lockActor(ins)
  return { op = "lock_actor", actor = actorRef(ins.operands[1]) }
end

local function releaseActor(ins)
  return { op = "release_actor", actor = actorRef(ins.operands[1]) }
end

local function showObject(ins)
  return { op = "show_object", actor = actorRef(ins.operands[1]) }
end

local function hideObject(ins)
  return { op = "hide_object", actor = actorRef(ins.operands[1]) }
end

local function facePlayer()
  return { op = "face_player" }
end

local function getPlayerCoords(ins)
  return {
    op = "get_player_coords",
    x = Operands.varRef(ins.operands[1]),
    z = Operands.varRef(ins.operands[2]),
  }
end

local function getObjectCoords(ins)
  return {
    op = "get_object_coords",
    actor = actorRef(ins.operands[1]),
    x = Operands.varRef(ins.operands[2]),
    z = Operands.varRef(ins.operands[3]),
  }
end

local function genderedMessage(ins)
  return {
    op = "npc_msg",
    message = {
      text = "gendered_message",
      male = messageRef(Operands.operandValue(ins.operands[1])),
      female = messageRef(Operands.operandValue(ins.operands[2])),
    },
  }
end

local function yieldFollowerCheck()
  return { op = "yield_tick" }
end

local function setSpecialSpawn(ins)
  return {
    op = "set_special_spawn",
    map = Operands.varRef(ins.operands[1]),
    fieldX = Operands.varRef(ins.operands[2]),
    fieldZ = Operands.varRef(ins.operands[3]),
    warpId = -1,
    direction = "south",
  }
end

local function setFollowerInactive(ins)
  return { op = "set_var", variable = Operands.varRef(ins.operands[1]), value = 0 }
end

local function setBadgeInactive(ins)
  return { op = "set_var", variable = Operands.varRef(ins.operands[2]), value = 0 }
end

local function setFriendSprite(ins)
  return { op = "set_var", variable = Operands.varRef(ins.operands[1]), value = { value = "friend_sprite_value" } }
end

local function warp(ins)
  -- Warp map, warp, x, z, dir: coordinates and direction may be variable
  -- operands; numeric directions normalize to the string enum.
  return {
    op = "warp",
    map = Operands.varRef(ins.operands[1]),
    warp = Operands.varRef(ins.operands[2]),
    fieldX = Operands.varRef(ins.operands[3]),
    fieldZ = Operands.varRef(ins.operands[4]),
    facing = normalizeFacing(Operands.operandValue(ins.operands[5])),
  }
end

local function bufferPlayerName(ins)
  return { op = "buffer_text", slot = Operands.operandValue(ins.operands[1]), value = { text = "player_name" } }
end

local function bufferRivalName(ins)
  return { op = "buffer_text", slot = Operands.operandValue(ins.operands[1]), value = { text = "rival_name" } }
end

local function bufferFriendName(ins)
  return { op = "buffer_text", slot = Operands.operandValue(ins.operands[1]), value = { text = "friend_name" } }
end

local function bufferPartySpeciesName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "party_species_name", position = Operands.operandValue(ins.operands[2]) },
  }
end

local function bufferItemName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "item_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferPocketName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "pocket_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferTmhmMoveName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "tmhm_move_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferMoveName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "move_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferInteger(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "integer", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferPartyNickname(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "party_nickname", position = Operands.operandValue(ins.operands[2]) },
  }
end

local function bufferTrainerClassName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "trainer_class_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferSpeciesName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "species_name", value = Operands.operandValue(ins.operands[2]) },
  }
end

local function bufferStarterSpeciesName(ins)
  return { op = "buffer_text", slot = Operands.operandValue(ins.operands[1]), value = { text = "starter_species_name" } }
end

local function bufferMapName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "map_name", value = Operands.operandValue(ins.operands[2]) },
  }
end

local function setObjectPosition(ins)
  return {
    op = "set_object_position",
    actor = actorRef(ins.operands[1]),
    fieldX = Operands.varRef(ins.operands[2]),
    fieldZ = Operands.varRef(ins.operands[3]),
  }
end

local function movePersonFacing(ins)
  -- ScrCmd_MovePersonFacing reads objectId, x, y, z, direction.
  local actor = actorRef(ins.operands[1])
  return {
    steps = {
      {
        op = "set_object_position",
        actor = actor,
        fieldX = Operands.varRef(ins.operands[2]),
        worldY = Operands.varRef(ins.operands[3]),
        fieldZ = Operands.varRef(ins.operands[4]),
      },
      {
        op = "set_object_facing",
        actor = actor,
        direction = normalizeFacing(Operands.operandValue(ins.operands[5])),
      },
    },
  }
end

local function setObjectMovementType(ins)
  return {
    op = "set_object_movement_type",
    actor = actorRef(ins.operands[1]),
    movementType = tostring(Operands.operandValue(ins.operands[2])),
  }
end

local function setObjectFacing(ins)
  return {
    op = "set_object_facing",
    actor = actorRef(ins.operands[1]),
    direction = normalizeFacing(Operands.operandValue(ins.operands[2])),
  }
end

local function showWaitingIcon()
  return { op = "show_waiting_icon" }
end

local function hideWaitingIcon()
  return { op = "hide_waiting_icon" }
end

local function waitInputOrTicks(ins)
  return { op = "wait_input_or_ticks", ticks = Operands.operandValue(ins.operands[1]) }
end

local function showObjectAt(ins)
  return { op = "show_object", actor = actorRef(ins.operands[1]) }
end

local function waitButton()
  return "unfolded"
end

local function externalMessage(ins)
  return {
    op = "message",
    message = { message = "external", bank = Operands.varRef(ins.operands[1]), id = Operands.varRef(ins.operands[2]) },
    waitForPrint = false,
  }
end

local function externalMessageWait(ins)
  return {
    op = "message",
    message = { message = "external", bank = Operands.varRef(ins.operands[1]), id = Operands.varRef(ins.operands[2]) },
    waitForPrint = true,
  }
end

local function standardMenuBegin(ins)
  return {
    op = "menu_begin",
    messageSource = "standard",
    sourcePlacement = {
      system = MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT,
      x = Operands.operandValue(ins.operands[1]),
      y = Operands.operandValue(ins.operands[2]),
    },
    initialCursor = Operands.operandValue(ins.operands[3]),
    cancellable = Operands.operandValue(ins.operands[4]) ~= 0,
    result = Operands.varRef(ins.operands[5]),
  }
end

local function scriptMenuBegin(ins, memberIr)
  assert(memberIr.messageBank ~= nil, "script menu requires a current script message bank")
  return {
    op = "menu_begin",
    messageSource = { kind = "script", bank = memberIr.messageBank },
    sourcePlacement = {
      system = MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT,
      x = Operands.operandValue(ins.operands[1]),
      y = Operands.operandValue(ins.operands[2]),
    },
    initialCursor = Operands.operandValue(ins.operands[3]),
    cancellable = Operands.operandValue(ins.operands[4]) ~= 0,
    result = Operands.varRef(ins.operands[5]),
  }
end

local function menuAdd(ins)
  return {
    op = "menu_add",
    messageId = Operands.varRef(ins.operands[1]),
    vanillaMetadata = Operands.varRef(ins.operands[2]),
    value = Operands.varRef(ins.operands[3]),
  }
end

local function menuExecute()
  return { op = "menu_exec" }
end

local function lockLastTalkedActor()
  return { op = "lock_actor", actor = { ref = "actor", special = "last_talked" }, waitUntilPausable = true }
end

local function hideAuxiliaryUi()
  return { op = "set_auxiliary_ui_visible", visible = false }
end

local function showAuxiliaryUi()
  return { op = "set_auxiliary_ui_visible", visible = true }
end

local function contextChoice(ins)
  return { op = "context_choice", result = Operands.varRef(ins.operands[1]) }
end

local function processSoundplate()
  return { op = "process_soundplate" }
end

return {
  [44] = nonNpcMessage,
  [45] = npcMessage,
  [46] = nonNpcMessageVar,
  [47] = npcMessageVar,
  [49] = waitInput,
  [50] = waitInputTurn,
  [51] = waitInputNoTurn,
  [52] = openMessage,
  [53] = closeMessage,
  [54] = holdMessage,
  [55] = directionSignpost,
  [56] = setSignpostMap,
  [57] = setSignpostAction,
  [58] = waitSignpostAction,
  [59] = trainerTipsPrint,
  [60] = waitSignpost,
  [61] = requestStartMenu,
  [63] = askYesNo,
  [94] = applyMovement,
  [95] = waitMovement,
  [96] = lockAll,
  [97] = releaseAll,
  [98] = lockActor,
  [99] = releaseActor,
  [100] = showObject,
  [101] = hideObject,
  [104] = facePlayer,
  [105] = getPlayerCoords,
  [106] = getObjectCoords,
  [132] = genderedMessage,
  [144] = setFriendSprite,
  [176] = warp,
  [190] = bufferPlayerName,
  [191] = bufferRivalName,
  [192] = bufferFriendName,
  [193] = bufferPartySpeciesName,
  [194] = bufferItemName,
  [195] = bufferPocketName,
  [196] = bufferTmhmMoveName,
  [197] = bufferMoveName,
  [198] = bufferInteger,
  [199] = bufferPartyNickname,
  [200] = bufferTrainerClassName,
  [202] = bufferSpeciesName,
  [203] = bufferStarterSpeciesName,
  [210] = bufferMapName,
  [338] = setObjectPosition,
  [339] = movePersonFacing,
  [340] = setObjectMovementType,
  [341] = setObjectFacing,
  [345] = showWaitingIcon,
  [346] = hideWaitingIcon,
  [348] = waitInputOrTicks,
  [375] = showObjectAt,
  [438] = waitButton,
  [439] = externalMessage,
  [440] = externalMessageWait,
  [749] = standardMenuBegin,
  [750] = scriptMenuBegin,
  [751] = menuAdd,
  [752] = menuExecute,
  [581] = lockLastTalkedActor,
  [582] = setSpecialSpawn,
  [609] = yieldFollowerCheck,
  [729] = setFollowerInactive,
  [294] = setBadgeInactive,
  [746] = hideAuxiliaryUi,
  [747] = showAuxiliaryUi,
  [748] = contextChoice,
  [726] = processSoundplate,
}
