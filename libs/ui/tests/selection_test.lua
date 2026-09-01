-- Selection owns one selected zero-based index in a fixed non-empty range.

local Assert = require("tests.support.Assert")
local T = {}

local function selectionModule()
  local ok, moduleOrError = pcall(require, "libs.ui.src.Selection")
  Assert.isTrue(ok, "the reusable Selection primitive must exist: " .. tostring(moduleOrError))
  return moduleOrError
end

function T.constructor_defaults_to_the_first_index_of_a_positive_range()
  local Selection = selectionModule()
  local selection = Selection.new(3)

  Assert.equal(selection:itemCount(), 3)
  Assert.equal(selection:selectedIndex(), 0)
end

function T.constructor_preserves_a_valid_initial_index()
  local Selection = selectionModule()
  local selection = Selection.new(4, 3)

  Assert.equal(selection:itemCount(), 4)
  Assert.equal(selection:selectedIndex(), 3)
end

function T.assignment_updates_only_the_selected_index_in_the_fixed_range()
  local Selection = selectionModule()
  local selection = Selection.new(3, 1)

  Assert.isNil(selection:setSelectedIndex(2))
  Assert.equal(selection:itemCount(), 3)
  Assert.equal(selection:selectedIndex(), 2)

  Assert.isNil(selection:setSelectedIndex(2))
  Assert.equal(selection:selectedIndex(), 2)
end

function T.constructor_rejects_non_positive_or_non_integer_counts()
  local Selection = selectionModule()
  for _, itemCount in ipairs({ 0, -1, 1.5, math.huge, -math.huge, 0 / 0 }) do
    Assert.throws(function()
      Selection.new(itemCount)
    end)
  end
end

function T.constructor_rejects_invalid_initial_indexes()
  local Selection = selectionModule()
  for _, selectedIndex in ipairs({ false, -1, 3, 1.5, math.huge, -math.huge, 0 / 0 } --[[@as any]]) do
    Assert.throws(function()
      Selection.new(3, selectedIndex)
    end)
  end
end

function T.assignment_rejects_invalid_indexes_and_preserves_the_current_index()
  local Selection = selectionModule()
  local selection = Selection.new(3, 1)

  for _, selectedIndex in ipairs({ false, -1, 3, 1.5, math.huge, -math.huge, 0 / 0 } --[[@as any]]) do
    Assert.throws(function()
      selection:setSelectedIndex(selectedIndex)
    end)
    Assert.equal(selection:selectedIndex(), 1)
  end
end

return { tests = T }
