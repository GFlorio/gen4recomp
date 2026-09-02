-- Pure field-menu controller tests. These pin selection and completion
-- semantics independently of layout, rendering, input mapping, or scripts.

local Assert = require("tests.support.Assert")
local FieldMenuController = require("libs.hgss.src.ui.FieldMenuController")

local T = {}

local function menu(opts)
  opts = opts or {}
  return FieldMenuController.new({
    items = opts.items or {
      { text = "First", value = 70 },
      { text = "Second", value = 20 },
      { text = "Third", value = 70 },
    },
    initialCursor = opts.initialCursor,
    cancellable = opts.cancellable == true,
    cancelValue = opts.cancelValue,
  })
end

function T.initial_cursor_is_zero_based_and_validated()
  Assert.equal(menu():status().selectedIndex, 0)
  Assert.equal(menu({ initialCursor = 2 }):status().selectedIndex, 2)
  Assert.throws(function()
    menu({ initialCursor = 99 })
  end)
  Assert.throws(function()
    menu({ initialCursor = -4 })
  end)
end

function T.invalid_focus_preserves_the_selected_value()
  local controller = menu({ initialCursor = 1 })
  Assert.equal(controller:status().selectedIndex, 1)

  controller:focus(2)
  Assert.equal(controller:status().selectedIndex, 2)

  Assert.throws(function()
    controller:focus(3)
  end)
  Assert.equal(controller:status().selectedIndex, 2)
end

function T.layout_targeted_focus_stays_in_bounds()
  local controller = menu({ initialCursor = 1 })
  controller:focus(0)
  Assert.equal(controller:status().selectedIndex, 0)
  controller:focus(2)
  Assert.equal(controller:status().selectedIndex, 2)
  Assert.throws(function()
    controller:focus(3)
  end)
end

function T.confirm_retains_the_selected_item_value_not_its_visual_index()
  local controller = menu({ initialCursor = 1 })
  Assert.equal(controller:confirm(), 20)
  local status = controller:status()
  Assert.equal(status.state, "complete")
  Assert.equal(status.result, 20)
  Assert.isFalse(status.cancelled)
  Assert.equal(controller:confirm(), nil, "a completed menu cannot complete again")
end

function T.duplicate_labels_and_values_remain_valid()
  local controller = menu({
    items = {
      { text = "Same", value = 9 },
      { text = "Same", value = 9 },
    },
    initialCursor = 1,
  })
  Assert.equal(controller:confirm(), 9)
  Assert.equal(controller:status().selectedIndex, 1)
end

function T.cancel_only_completes_when_enabled()
  local blocked = menu()
  Assert.equal(blocked:cancel(), nil)
  Assert.equal(blocked:status().state, "active")

  local cancellable = menu({ cancellable = true, cancelValue = 0xFFFE })
  Assert.equal(cancellable:cancel(), 0xFFFE)
  local status = cancellable:status()
  Assert.equal(status.state, "complete")
  Assert.equal(status.result, 0xFFFE)
  Assert.isTrue(status.cancelled)
end

function T.cancellable_menu_requires_a_cancellation_result()
  Assert.throws(function()
    menu({ cancellable = true })
  end)
end

function T.cancellable_menu_can_return_false()
  local controller = menu({ cancellable = true, cancelValue = false })
  Assert.equal(controller:cancel(), false)
end

function T.cancellable_must_be_a_boolean()
  Assert.throws(function()
    FieldMenuController.new({
      items = {
        { text = "Only", value = 1 },
      },
      cancellable = 1,
    } --[[@as any]])
  end)
end

function T.empty_menu_is_rejected()
  Assert.throws(function()
    menu({ items = {} })
  end)
end

function T.pointer_requires_matching_press_and_release()
  local controller = menu()
  controller:hover(1)
  Assert.equal(controller:status().selectedIndex, 1)
  controller:press(1)
  Assert.equal(controller:release(1), 20)
  Assert.equal(controller:status().result, 20)
end

function T.pointer_drag_and_invalid_items_do_not_activate()
  local controller = menu()
  controller:press(0)
  Assert.equal(controller:release(1), nil)
  Assert.equal(controller:status().state, "active")
  Assert.equal(controller:release(0), nil, "a mismatched release clears pointer capture")
  Assert.equal(controller:status().state, "active")
  Assert.throws(function()
    controller:hover(3)
  end)
end

function T.directional_navigation_restores_focus_after_pointer_hover()
  local controller = menu()
  controller:hover(2)
  controller:focus(1)
  Assert.equal(controller:status().selectedIndex, 1)
end

return { tests = T }
