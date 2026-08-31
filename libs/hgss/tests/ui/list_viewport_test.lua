-- ListViewport owns deterministic first-visible-row state for vertical lists.

local Assert = require("tests.support.Assert")
local T = {}

local function listViewportModule()
  local ok, moduleOrError = pcall(require, "libs.hgss.src.ui.ListViewport")
  Assert.isTrue(ok, "the reusable ListViewport primitive must exist: " .. tostring(moduleOrError))
  return moduleOrError
end

local function viewport(itemCount, visibleRows, selectedIndex)
  local ListViewport = listViewportModule()
  return ListViewport.new({
    itemCount = itemCount,
    visibleRows = visibleRows,
    selectedIndex = selectedIndex,
  })
end

function T.zero_items_have_an_empty_visible_range()
  local range = viewport(0, 3):visibleRange()
  Assert.equal(range.first, nil)
  Assert.equal(range.last, nil)
end

function T.short_and_exact_capacity_lists_start_at_the_first_row()
  local short = viewport(2, 3)
  Assert.equal(short:firstVisibleRow(), 0)
  Assert.equal(short:visibleRange().last, 1)

  local exact = viewport(3, 3, 2)
  Assert.equal(exact:firstVisibleRow(), 0)
  Assert.equal(exact:visibleRange().last, 2)
end

function T.selection_advances_the_viewport_only_when_it_leaves_the_range()
  local list = viewport(6, 3)
  list:setSelectedIndex(2)
  Assert.equal(list:firstVisibleRow(), 0)
  list:setSelectedIndex(3)
  Assert.equal(list:firstVisibleRow(), 1)
  list:setSelectedIndex(5)
  Assert.deepEqual(list:visibleRange(), { first = 3, last = 5 })
end

function T.one_row_viewports_keep_the_selected_row_visible()
  local list = viewport(3, 1, 1)
  Assert.deepEqual(list:visibleRange(), { first = 1, last = 1 })
  list:setSelectedIndex(2)
  Assert.deepEqual(list:visibleRange(), { first = 2, last = 2 })
end

function T.shrinking_lists_clamp_the_range_and_selection()
  local list = viewport(8, 3, 7)
  list:setItemCount(2)
  Assert.equal(list:selectedIndex(), 1)
  Assert.deepEqual(list:visibleRange(), { first = 0, last = 1 })
end

function T.visible_row_capacity_must_be_a_positive_integer()
  local ListViewport = listViewportModule()
  Assert.throws(function()
    ListViewport.new({ itemCount = 1, visibleRows = 0 })
  end)
  Assert.throws(function()
    ListViewport.new({ itemCount = 1, visibleRows = 1.5 } --[[@as any]])
  end)
end

return { tests = T }
