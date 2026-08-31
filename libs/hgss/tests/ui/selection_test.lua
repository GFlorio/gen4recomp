-- Selection owns zero-based focus state for an ordered selectable range.

local Assert = require("tests.support.Assert")
local T = {}

local function selectionModule()
  local ok, moduleOrError = pcall(require, "libs.hgss.src.ui.Selection")
  Assert.isTrue(ok, "the reusable Selection primitive must exist: " .. tostring(moduleOrError))
  return moduleOrError
end

function T.empty_selection_has_no_selected_index()
  local Selection = selectionModule()
  local selection = Selection.new(0)
  Assert.equal(selection:itemCount(), 0)
  Assert.isNil(selection:selectedIndex())
  Assert.isFalse(selection:hasSelection())
end

function T.non_empty_selection_uses_the_optional_initial_index()
  local Selection = selectionModule()
  Assert.equal(Selection.new(3):selectedIndex(), 0)
  Assert.equal(Selection.new(3, 2):selectedIndex(), 2)
  Assert.isTrue(Selection.new(3):hasSelection())
end

function T.movement_clamps_at_both_edges()
  local Selection = selectionModule()
  local selection = Selection.new(3, 1)
  Assert.equal(selection:move(-10), 0)
  Assert.equal(selection:move(10), 2)
  Assert.equal(selection:move(0), 2)
end

function T.item_count_changes_normalize_the_selected_index()
  local Selection = selectionModule()
  local selection = Selection.new(4, 3)
  selection:setItemCount(2)
  Assert.equal(selection:selectedIndex(), 1)
  selection:setItemCount(0)
  Assert.isNil(selection:selectedIndex())
  selection:setItemCount(3)
  Assert.equal(selection:selectedIndex(), 0)
end

function T.observation_does_not_expose_writable_selection_state()
  local Selection = selectionModule()
  local selection = Selection.new(2, 1)
  local status = selection:status()
  status.selectedIndex = 0
  Assert.equal(selection:selectedIndex(), 1)
  Assert.throws(function()
    selection:setItemCount(-1)
  end)
end

return { tests = T }
