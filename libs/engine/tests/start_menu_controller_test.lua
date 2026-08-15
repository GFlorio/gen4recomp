-- The pure Start Menu controller: final interactive action display, optional
-- selection, the folded-in fixed-tick cursor animation, confirm/cancel/
-- menu-key close, and touch/pointer slot interaction. The controller receives
-- the runtime-composed final action list (each entry already intersected with
-- the registered destination capabilities, carrying only id /
-- targetApplication / displayPosition) and the generated manifest slot
-- surface; it carries no labels, no product-mode projections, and no
-- capability or progression knowledge. An empty action list is first-class:
-- the menu opens with no selection, navigation/confirm are safe no-ops,
-- pointer action slots are inert, the cancel region stays live, and no cursor
-- is presented or animated. The cursor animation is the manifest frame
-- durations stepped exactly once per fixed tick while a selection exists.
-- The controller is silent: it never names a ROM sequence and never touches
-- love. No application launches happen here: the controller records the
-- takeResult contract and the host launches.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local StartMenuController = require("libs.engine.src.StartMenuController")

local T = {}

local SLOTS = FieldUiFixture.START_MENU_SLOTS
local CURSOR_FRAMES = FieldUiFixture.START_MENU_CURSOR_FRAMES

-- The full-progression interactive list (every destination registered):
-- display positions 0..6 plus the special Pokégear-family entries at the
-- reserved positions 7/8.
local function fullEntries()
  return {
    { id = "vanilla.pokedex", targetApplication = "pokedex", displayPosition = 0 },
    { id = "vanilla.pokemon", targetApplication = "pokemon", displayPosition = 1 },
    { id = "vanilla.bag", targetApplication = "bag", displayPosition = 2 },
    { id = "vanilla.pokegear", targetApplication = "pokegear", displayPosition = 3 },
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 4 },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 5 },
    { id = "vanilla.options", targetApplication = "options", displayPosition = 6 },
    { id = "vanilla.special_9", targetApplication = "pokegear", displayPosition = 7 },
    { id = "vanilla.special_10", targetApplication = "pokegear", displayPosition = 8 },
  }
end

-- A fresh-game interactive list: only the trainer card destination exists.
local function freshEntries()
  return { { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0 } }
end

---@param opts table?
---@return StartMenuController
local function newController(opts)
  opts = opts or {}
  local controller = StartMenuController.new({
    entries = opts.entries ~= nil and opts.entries or fullEntries(),
    slots = opts.slots or SLOTS,
    cursorFrames = opts.cursorFrames or CURSOR_FRAMES,
    rememberedActionId = opts.rememberedActionId,
  })
  return controller
end

local function slotCenter(slotId)
  local rect = assert(SLOTS[slotId], "fixture slot " .. slotId .. " required")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

function T.construction_succeeds_with_only_the_documented_options()
  local controller = newController()
  Assert.equal(controller:status().open, true)
end

function T.visible_actions_follow_positions_and_slot_ids()
  local controller = newController()
  local status = controller:status()
  Assert.equal(status.open, true)
  Assert.equal(status.cancelSlotId, 1, "the cancel touch region is slot 1")
  Assert.deepEqual(status.actions, {
    { id = "vanilla.pokedex", targetApplication = "pokedex", position = 0, slotId = 2 },
    { id = "vanilla.pokemon", targetApplication = "pokemon", position = 1, slotId = 3 },
    { id = "vanilla.bag", targetApplication = "bag", position = 2, slotId = 4 },
    { id = "vanilla.pokegear", targetApplication = "pokegear", position = 3, slotId = 5 },
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", position = 4, slotId = 6 },
    { id = "vanilla.save", targetApplication = "save", position = 5, slotId = 7 },
    { id = "vanilla.options", targetApplication = "options", position = 6, slotId = 8 },
    { id = "vanilla.special_9", targetApplication = "pokegear", position = 7, slotId = 9 },
    { id = "vanilla.special_10", targetApplication = "pokegear", position = 8, slotId = 10 },
  })
  Assert.equal(status.cursorSlotId, 2, "the default selection is the first visible action")
  Assert.equal(status.cursorFrameIndex, 0, "a selected menu presents the cursor animation frame")
end

function T.actions_carry_only_id_destination_position_and_slot()
  local actions = newController():status().actions
  for _, action in ipairs(actions) do
    local keys = {}
    for key in pairs(action) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    Assert.deepEqual(keys, { "id", "position", "slotId", "targetApplication" }, "no labels or product-mode projections")
  end
end

function T.selection_restores_by_remembered_action_id()
  local controller = newController({ rememberedActionId = "vanilla.bag" })
  Assert.equal(controller:status().cursorSlotId, 4, "the remembered action restores its display slot")
end

function T.selection_falls_back_to_the_first_action_when_the_remembered_id_is_absent()
  local controller = newController({ rememberedActionId = "vanilla.running_shoes" })
  Assert.equal(controller:status().cursorSlotId, 2, "an absent remembered id falls back to the first action")
end

-- The empty menu is a first-class state: constructing it succeeds, the
-- presentation carries no selection and no cursor, and the cancel region
-- stays live.
function T.an_empty_menu_opens_with_no_selection_and_no_cursor()
  local controller = newController({ entries = {} })
  local status = controller:status()
  Assert.equal(status.open, true)
  Assert.deepEqual(status.actions, {})
  Assert.equal(status.cancelSlotId, 1)
  Assert.isNil(status.cursorSlotId, "an empty menu must not select an action")
  Assert.isNil(status.cursorFrameIndex, "an empty menu must not present a cursor")
  Assert.isNil(controller:takeResult())
end

function T.empty_menu_navigation_and_confirm_are_safe_noops()
  local controller = newController({ entries = {} })
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    controller:updateFixed({ { type = "navigate", direction = direction } })
  end
  Assert.equal(controller:status().open, true, "navigation must leave the empty menu open")
  Assert.deepEqual(controller:status().actions, {}, "navigation must not fabricate actions")
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "confirm on no selection records no result")
  Assert.equal(controller:status().open, true, "confirm must leave the empty menu open")
end

function T.empty_menu_cancel_and_menu_events_close()
  local cancelController = newController({ entries = {} })
  cancelController:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(cancelController:takeResult(), { kind = "close" })

  local menuController = newController({ entries = {} })
  menuController:updateFixed({ { type = "menu" } })
  Assert.deepEqual(menuController:takeResult(), { kind = "close" })
end

function T.empty_menu_pointer_slots_are_inert_and_the_cancel_region_closes()
  local controller = newController({ entries = {} })
  local actionX, actionY = slotCenter(2)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = actionX, y = actionY } })
  Assert.isNil(controller:status().cursorSlotId, "hovering an action slot with no action changes nothing")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = actionX, y = actionY } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = actionX, y = actionY, dragged = false } })
  Assert.isNil(controller:takeResult(), "an action-slot tap must not launch from an empty menu")
  Assert.equal(controller:status().open, true)

  local cancelX, cancelY = slotCenter(1)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = cancelX, y = cancelY } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = cancelX, y = cancelY, dragged = false } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
end

function T.empty_menu_cursor_animation_never_advances()
  local controller = newController({ entries = {} })
  for _ = 1, 64 do
    controller:updateFixed({})
  end
  Assert.isNil(controller:status().cursorFrameIndex, "no selection means no cursor animation")
  Assert.isNil(controller:status().cursorSlotId)
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
  local controller = newController({
    entries = {
      { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0 },
      { id = "vanilla.save", targetApplication = "save", displayPosition = 1 },
      { id = "vanilla.options", targetApplication = "options", displayPosition = 2 },
      { id = "vanilla.special_9", targetApplication = "pokegear", displayPosition = 7 },
      { id = "vanilla.special_10", targetApplication = "pokegear", displayPosition = 8 },
    },
  })
  -- positions 0,1,2,7,8 are filled; 3..6 are holes.
  for _ = 1, 4 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(controller:status().cursorSlotId, 10, "navigation must skip empty display positions")
end

function T.confirm_launches_the_selected_application()
  local controller = newController()
  for _ = 1, 4 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "trainer_card",
    actionId = "vanilla.trainer_card",
  })
  Assert.equal(controller:status().open, false, "a taken result ends the menu lifetime")
end

function T.cancel_and_the_menu_event_close()
  local controller = newController()
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })

  local menuController = newController()
  menuController:updateFixed({ { type = "menu" } })
  Assert.deepEqual(menuController:takeResult(), { kind = "close" })
end

function T.a_terminal_event_ends_the_ticks_processing()
  local closeFirst = newController()
  closeFirst:updateFixed({ { type = "cancel" }, { type = "confirm" } })
  Assert.deepEqual(closeFirst:takeResult(), { kind = "close" }, "a close before a confirm in one tick must win")
  Assert.equal(closeFirst:status().open, false)

  local confirmFirst = newController()
  confirmFirst:updateFixed({ { type = "confirm" }, { type = "cancel" } })
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
  local controller = newController()
  local x, y = slotCenter(5)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  Assert.equal(controller:status().cursorSlotId, 5, "hover selects the hovered slot")
end

function T.pointer_down_up_on_the_same_action_slot_activates()
  local controller = newController()
  local x, y = slotCenter(6)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.equal(controller:status().cursorSlotId, 6, "pointer down selects the pressed slot")
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
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

function T.pointer_cancel_slot_down_up_closes()
  local controller = newController()
  local x, y = slotCenter(1)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
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

-- A placement change cancels the active pointer capture, so a press held
-- across a layout change cannot activate a different post-change slot.
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
  -- Display positions 4..6 are holes in this list, so slots 6..8 have no
  -- action.
  local controller = newController({
    entries = {
      { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0 },
      { id = "vanilla.save", targetApplication = "save", displayPosition = 1 },
      { id = "vanilla.options", targetApplication = "options", displayPosition = 2 },
      { id = "vanilla.special_9", targetApplication = "pokegear", displayPosition = 7 },
      { id = "vanilla.special_10", targetApplication = "pokegear", displayPosition = 8 },
    },
  })
  local x, y = slotCenter(7)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  Assert.equal(controller:status().cursorSlotId, 2, "hovering an empty slot must not move the selection")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(controller:takeResult(), "a press on an empty slot must not activate anything")
  Assert.equal(controller:status().open, true)
end

-- The cursor animation is folded into the controller: the manifest frame
-- durations are stepped exactly once per fixed tick while a selection
-- exists.
function T.cursor_animation_advances_on_fixed_ticks_while_selected()
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

function T.construction_rejects_malformed_input()
  local function with(overrides)
    local opts = {
      entries = fullEntries(),
      slots = SLOTS,
      cursorFrames = CURSOR_FRAMES,
    }
    for key, value in pairs(overrides) do
      opts[key] = value
    end
    return opts
  end
  Assert.throws(function()
    StartMenuController.new(with({ entries = { { id = "", targetApplication = "save", displayPosition = 0 } } }))
  end, "entries need an id")
  Assert.throws(function()
    StartMenuController.new(with({ entries = { { id = "vanilla.save", displayPosition = 0 } } }))
  end, "interactive entries need a destination")
  Assert.throws(function()
    StartMenuController.new(with({ entries = { { id = "vanilla.save", targetApplication = "save" } } }))
  end, "entries need a display position")
  Assert.throws(function()
    StartMenuController.new(
      with({ entries = { { id = "vanilla.save", targetApplication = "save", displayPosition = 9 } } })
    )
  end, "a position beyond the slot capacity is rejected")
  Assert.throws(function()
    StartMenuController.new(with({ slots = {} }))
  end, "the manifest slot surface is required")
  Assert.throws(function()
    StartMenuController.new(with({ cursorFrames = {} }))
  end, "the cursor animation requires frames")
  Assert.throws(function()
    StartMenuController.new(with({ cursorFrames = { { duration = 0 } } }))
  end, "cursor frame durations must be positive")
end

return { tests = T }
