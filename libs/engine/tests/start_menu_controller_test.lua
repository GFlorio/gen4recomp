-- The pure Start Menu controller: visible action composition from the
-- StartMenuPolicy build output (the source display-array overwrite semantics,
-- capability visibility per product mode), selection with remembered-action
-- restore, confirm/cancel/menu-key close, touch/pointer slot selection with
-- down/up-mismatch and drag discrimination, the fixed-tick cursor animation
-- step, and the three §21.1 semantic sound requests through a required
-- application-audio facade (injected recorder; the controller never names a
-- ROM sequence and never touches love). No application launches happen here:
-- the controller records the takeResult contract and the host launches.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")
local StartMenuController = require("libs.engine.src.StartMenuController")

local T = {}

local SLOTS = FieldUiFixture.START_MENU_SLOTS
local CURSOR_FRAMES = FieldUiFixture.START_MENU_CURSOR_FRAMES

-- Full-progression normal-field policy entries: every §19 action present,
-- every progression gate open. Visible with the matching capabilities:
-- pokedex..options at display positions 0..6, special 9 at 7 (overwriting the
-- running-shoes slot), special 10 at 8. Slot ids are the touch ids: cancel is
-- slot 1 and display position p occupies slot p+2.
local function fullPolicy()
  return StartMenuPolicy.build({
    context = "normal_field",
    progression = { hasPokedex = true, hasStarter = true, bagUnlocked = true, hasPokegear = true },
    capabilities = { "pokedex", "pokemon", "bag", "pokegear", "trainer_card", "save", "options" },
  })
end

-- Fresh-game normal-field policy: only trainer_card/save/options/running_shoes
-- present, no progression, and (in normal mode) only the capability-backed
-- entries visible: trainer_card at 0, save at 1, options at 2, holes at 3..6,
-- special 9 at 7 and special 10 at 8 (both hidden without the pokegear
-- capability in normal mode).
local function freshPolicy()
  return StartMenuPolicy.build({
    context = "normal_field",
    progression = { hasPokedex = false, hasStarter = false, bagUnlocked = false, hasPokegear = false },
    capabilities = { "trainer_card" },
  })
end

-- Fresh-game policy viewed in development mode: everything present is
-- visible, including capability-missing entries in their disabled state.
local function freshDevPolicy()
  return StartMenuPolicy.build({
    context = "normal_field",
    progression = { hasPokedex = false, hasStarter = false, bagUnlocked = false, hasPokegear = false },
    capabilities = {},
  })
end

local function recorder()
  local requests = {}
  return {
    requests = requests,
    play = function(_, requestId)
      requests[#requests + 1] = requestId
    end,
  }
end

---@param opts table?
---@return StartMenuController, table
local function newController(opts)
  opts = opts or {}
  local audio = opts.audio or recorder()
  local controller = StartMenuController.new({
    entries = opts.entries or fullPolicy(),
    development = opts.development == true,
    slots = opts.slots or SLOTS,
    cursorFrames = opts.cursorFrames or CURSOR_FRAMES,
    audio = audio,
    rememberedActionId = opts.rememberedActionId,
  })
  return controller, audio
end

local function slotCenter(slotId)
  local rect = assert(SLOTS[slotId], "fixture slot " .. slotId .. " required")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

function T.construction_requests_the_open_sound_exactly_once()
  local _, audio = newController()
  Assert.deepEqual(audio.requests, { "start_menu.open" }, "the open sound is requested exactly once at construction")
end

function T.visible_actions_follow_policy_positions_and_slot_ids()
  local controller = newController()
  local status = controller:status()
  Assert.equal(status.open, true)
  Assert.equal(status.cancelSlotId, 1, "the cancel touch region is slot 1")
  Assert.deepEqual(status.actions, {
    {
      id = "vanilla.pokedex",
      position = 0,
      slotId = 2,
      targetApplication = "pokedex",
      enabled = true,
      message = "msg.hgss.0196.00000",
    },
    {
      id = "vanilla.pokemon",
      position = 1,
      slotId = 3,
      targetApplication = "pokemon",
      enabled = true,
      message = "msg.hgss.0196.00001",
    },
    {
      id = "vanilla.bag",
      position = 2,
      slotId = 4,
      targetApplication = "bag",
      enabled = true,
      message = "msg.hgss.0196.00002",
    },
    {
      id = "vanilla.pokegear",
      position = 3,
      slotId = 5,
      targetApplication = "pokegear",
      enabled = true,
      message = "msg.hgss.0196.00014",
    },
    {
      id = "vanilla.trainer_card",
      position = 4,
      slotId = 6,
      targetApplication = "trainer_card",
      enabled = true,
      message = "msg.hgss.0196.00003",
    },
    {
      id = "vanilla.save",
      position = 5,
      slotId = 7,
      targetApplication = "save",
      enabled = true,
      message = "msg.hgss.0196.00004",
    },
    {
      id = "vanilla.options",
      position = 6,
      slotId = 8,
      targetApplication = "options",
      enabled = true,
      message = "msg.hgss.0196.00005",
    },
    {
      id = "vanilla.special_9",
      position = 7,
      slotId = 9,
      targetApplication = "pokegear",
      enabled = true,
      message = "msg.hgss.0196.00014",
    },
    {
      id = "vanilla.special_10",
      position = 8,
      slotId = 10,
      targetApplication = "pokegear",
      enabled = true,
      message = "msg.hgss.0196.00014",
    },
  })
  Assert.equal(status.cursorSlotId, 2, "the default selection is the first visible action")
end

function T.running_shoes_is_overwritten_by_the_reserved_phone_slots()
  local actions = newController():status().actions ---@type StartMenuController.Action[]
  for _, action in ipairs(actions) do
    Assert.isFalse(action.id == "vanilla.running_shoes", "special 9/10 overwrite the running-shoes display slot")
  end
end

function T.normal_mode_omits_capability_missing_actions_and_keeps_the_holes()
  local controller = newController({ entries = freshPolicy() })
  local actions = controller:status().actions
  Assert.deepEqual(actions, {
    {
      id = "vanilla.trainer_card",
      position = 0,
      slotId = 2,
      targetApplication = "trainer_card",
      enabled = true,
      message = "msg.hgss.0196.00003",
    },
  })
end

function T.development_mode_shows_capability_missing_actions_disabled()
  local controller = newController({ entries = freshDevPolicy(), development = true })
  local actions = controller:status().actions
  Assert.deepEqual(actions, {
    {
      id = "vanilla.trainer_card",
      position = 0,
      slotId = 2,
      targetApplication = "trainer_card",
      enabled = false,
      message = "msg.hgss.0196.00003",
    },
    {
      id = "vanilla.save",
      position = 1,
      slotId = 3,
      targetApplication = "save",
      enabled = false,
      message = "msg.hgss.0196.00004",
    },
    {
      id = "vanilla.options",
      position = 2,
      slotId = 4,
      targetApplication = "options",
      enabled = false,
      message = "msg.hgss.0196.00005",
    },
    {
      id = "vanilla.running_shoes",
      position = 3,
      slotId = 5,
      targetApplication = nil,
      enabled = false,
      message = "msg.hgss.0196.00006",
    },
    {
      id = "vanilla.special_9",
      position = 7,
      slotId = 9,
      targetApplication = "pokegear",
      enabled = false,
      message = "msg.hgss.0196.00014",
    },
    {
      id = "vanilla.special_10",
      position = 8,
      slotId = 10,
      targetApplication = "pokegear",
      enabled = false,
      message = "msg.hgss.0196.00014",
    },
  })
end

function T.selection_restores_by_remembered_action_id()
  local controller = newController({ rememberedActionId = "vanilla.bag" })
  Assert.equal(controller:status().cursorSlotId, 4, "the remembered action restores its display slot")
end

function T.selection_falls_back_to_the_first_enabled_action_when_the_remembered_id_is_absent()
  -- running_shoes is overwritten by the reserved phone slots in full
  -- progression, so its id is genuinely absent from the visible display.
  local controller = newController({ rememberedActionId = "vanilla.running_shoes" })
  Assert.equal(controller:status().cursorSlotId, 2, "an absent remembered id falls back to the first visible action")
end

function T.construction_rejects_malformed_input()
  local function with(overrides)
    local opts = {
      entries = fullPolicy(),
      development = false,
      slots = SLOTS,
      cursorFrames = CURSOR_FRAMES,
      audio = recorder(),
    }
    for key, value in pairs(overrides) do
      opts[key] = value
    end
    return opts
  end
  Assert.throws(function()
    local opts = with({})
    opts.audio = nil
    StartMenuController.new(opts)
  end, "the audio facade is required")
  Assert.throws(function()
    StartMenuController.new(with({ audio = {} }))
  end, "the audio facade must play requests")
  Assert.throws(function()
    StartMenuController.new(with({ entries = {} }))
  end, "an empty menu cannot open")
  Assert.throws(function()
    StartMenuController.new(with({ slots = {} }))
  end, "the manifest slot surface is required")
  Assert.throws(function()
    StartMenuController.new(with({ cursorFrames = {} }))
  end, "the cursor animation requires frames")
  local emptyVisible = StartMenuPolicy.build({
    context = "normal_field",
    progression = { hasPokedex = false, hasStarter = false, bagUnlocked = false, hasPokegear = false },
    capabilities = {},
  })
  Assert.throws(function()
    StartMenuController.new(with({ entries = emptyVisible }))
  end, "a menu with no visible actions cannot open")
end

function T.directional_navigation_moves_and_wraps_across_visible_positions()
  local controller = newController()
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().cursorSlotId, 3, "down moves to the next display position")
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().cursorSlotId, 4, "right moves along the display order")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(controller:status().cursorSlotId, 3, "up moves back along the display order")
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(controller:status().cursorSlotId, 2, "left moves back along the display order")
  for _ = 1, 8 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(controller:status().cursorSlotId, 10, "the last visible position occupies the last display slot")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().cursorSlotId, 2, "navigation wraps from the last visible position to the first")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(controller:status().cursorSlotId, 10, "navigation wraps backward to the last visible position")
end

function T.navigation_skips_holes_in_the_display_array()
  local controller = newController({ entries = freshDevPolicy(), development = true })
  -- trainer_card(0) -> down -> save(1) -> down -> options(2) -> down ->
  -- running_shoes(3) -> down -> special_9(7): positions 4..6 are holes.
  for _ = 1, 4 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(controller:status().cursorSlotId, 9, "navigation must skip empty display positions")
end

function T.confirm_launches_the_selected_application_with_the_select_sound()
  local controller, audio = newController()
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(audio.requests, { "start_menu.open", "start_menu.select" })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "trainer_card",
    actionId = "vanilla.trainer_card",
  })
  Assert.equal(controller:status().open, false, "a taken result ends the menu lifetime")
end

function T.confirm_on_a_disabled_action_plays_the_select_sound_but_launches_nothing()
  local controller, audio = newController({ entries = freshDevPolicy(), development = true })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(audio.requests, { "start_menu.open", "start_menu.select" })
  Assert.isNil(controller:takeResult(), "a disabled action records no result")
  Assert.equal(controller:status().open, true, "a disabled confirm keeps the menu open")
end

function T.cancel_and_the_menu_event_close_with_the_cancel_sound()
  local controller, audio = newController()
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(audio.requests, { "start_menu.open", "start_menu.cancel" })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })

  local menuController, menuAudio = newController()
  menuController:updateFixed({ { type = "menu" } })
  Assert.deepEqual(menuAudio.requests, { "start_menu.open", "start_menu.cancel" })
  Assert.deepEqual(menuController:takeResult(), { kind = "close" })
end

function T.a_terminal_event_ends_the_ticks_processing()
  local closeFirst, closeAudio = newController()
  closeFirst:updateFixed({ { type = "cancel" }, { type = "confirm" } })
  Assert.deepEqual(
    closeAudio.requests,
    { "start_menu.open", "start_menu.cancel" },
    "a close stops the tick's sound requests"
  )
  Assert.deepEqual(closeFirst:takeResult(), { kind = "close" }, "a close before a confirm in one tick must win")
  Assert.equal(closeFirst:status().open, false)

  local confirmFirst, confirmAudio = newController()
  confirmFirst:updateFixed({ { type = "confirm" }, { type = "cancel" } })
  Assert.deepEqual(
    confirmAudio.requests,
    { "start_menu.open", "start_menu.select" },
    "a launch stops the tick's sound requests"
  )
  Assert.deepEqual(
    confirmFirst:takeResult(),
    { kind = "launch", applicationId = "pokedex", actionId = "vanilla.pokedex" },
    "a confirm before a cancel in one tick must win"
  )
end

function T.take_result_is_exactly_once_and_terminal()
  local controller = newController()
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
  Assert.isNil(controller:takeResult(), "the result is consumed exactly once")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().open, false, "a terminal controller stays closed")
end

function T.pointer_hover_moves_selection_without_activating()
  local controller, audio = newController()
  local x, y = slotCenter(5)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  Assert.equal(controller:status().cursorSlotId, 5, "hover selects the hovered slot")
  Assert.deepEqual(audio.requests, { "start_menu.open" }, "hover plays no sound")
end

function T.pointer_down_up_on_the_same_action_slot_activates()
  local controller, audio = newController()
  local x, y = slotCenter(6)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.equal(controller:status().cursorSlotId, 6, "pointer down selects the pressed slot")
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.deepEqual(audio.requests, { "start_menu.open", "start_menu.select" })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "trainer_card",
    actionId = "vanilla.trainer_card",
  })
end

function T.pointer_down_up_mismatch_and_drag_discard_the_activation()
  local mismatch = newController()
  local downX, downY = slotCenter(4)
  local upX, upY = slotCenter(5)
  mismatch:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = downX, y = downY } })
  mismatch:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = upX, y = upY, dragged = false } })
  Assert.isNil(mismatch:takeResult(), "a down/up mismatch must not activate")
  Assert.equal(mismatch:status().open, true)

  local dragged = newController()
  dragged:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = downX, y = downY } })
  dragged:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = downX, y = downY, dragged = true } })
  Assert.isNil(dragged:takeResult(), "a drag must not activate")
  Assert.equal(dragged:status().open, true)
end

function T.pointer_cancel_slot_down_up_closes_with_the_cancel_sound()
  local controller, audio = newController()
  local x, y = slotCenter(1)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.deepEqual(audio.requests, { "start_menu.open", "start_menu.cancel" })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
end

function T.pointer_cancel_mismatch_and_drag_do_not_close()
  local mismatch = newController()
  local x, y = slotCenter(1)
  local otherX, otherY = slotCenter(2)
  mismatch:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  mismatch:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = otherX, y = otherY, dragged = false } })
  Assert.isNil(mismatch:takeResult(), "a cancel-slot down/up mismatch must not close")
  Assert.equal(mismatch:status().open, true)

  local dragged = newController()
  dragged:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  dragged:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = true } })
  Assert.isNil(dragged:takeResult(), "a dragged cancel press must not close")
  Assert.equal(dragged:status().open, true)
end

function T.pointer_capture_ignores_other_pointers()
  local controller = newController()
  local firstX, firstY = slotCenter(6)
  local secondX, secondY = slotCenter(10)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = firstX, y = firstY } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:2", x = secondX, y = secondY } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:2", x = secondX, y = secondY, dragged = false } })
  Assert.isNil(controller:takeResult(), "a second pointer cannot steal the capture")
  Assert.equal(controller:status().open, true)
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = firstX, y = firstY, dragged = false } })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "trainer_card",
    actionId = "vanilla.trainer_card",
  })
end

-- §22.1/§41: a resize cancels the active pointer capture, so a press held
-- across a layout change cannot activate a different post-resize slot.
function T.cancel_pointer_capture_discards_the_held_press()
  local controller = newController()
  local x, y = slotCenter(6)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:cancelPointerCapture()
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(controller:takeResult(), "a cancelled capture cannot activate")
  Assert.equal(controller:status().open, true)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.notNil(controller:takeResult(), "a fresh press after the cancellation works normally")
end

function T.pointer_press_outside_any_slot_does_not_move_selection()
  local controller = newController()
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = 255, y = 191 } })
  Assert.equal(controller:status().cursorSlotId, 2, "a point outside the slot grid changes nothing")
end

function T.pointer_over_an_empty_display_position_changes_nothing()
  -- Fresh-game development menu: positions 0..3 and 7..8 are filled, so
  -- slots 6..8 (positions 4..6) are holes in the display array.
  local controller = newController({ entries = freshDevPolicy(), development = true })
  local x, y = slotCenter(7)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  Assert.equal(controller:status().cursorSlotId, 2, "hovering an empty slot must not move the selection")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(controller:takeResult(), "a press on an empty slot must not activate anything")
  Assert.equal(controller:status().open, true)
end

function T.cursor_animation_advances_on_fixed_ticks()
  local controller = newController()
  -- Fixture frames: frame 0 holds 22 ticks, frame 1 holds 11.
  for _ = 1, 21 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().cursorFrameIndex, 0, "the first frame holds for its duration")
  controller:updateFixed({})
  Assert.equal(controller:status().cursorFrameIndex, 1, "the animation advances exactly once per fixed tick")
end

function T.dispose_is_idempotent_and_discards_a_pending_result()
  local controller = newController()
  controller:updateFixed({ { type = "cancel" } })
  controller:dispose()
  controller:dispose()
  Assert.equal(controller:status().open, false)
  Assert.isNil(controller:takeResult(), "dispose discards the pending result")
end

return { tests = T }
