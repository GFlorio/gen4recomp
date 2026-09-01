-- ChoiceGroup is a pure resolved snapshot shared by hit testing and painting.

local Assert = require("tests.support.Assert")

local T = {}

local function choiceGroup()
  local ok, moduleOrError = pcall(require, "libs.ui.src.ChoiceGroup")
  Assert.isTrue(ok, "the reusable choice-group primitive must exist: " .. tostring(moduleOrError))
  return moduleOrError
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function validSpec()
  return {
    selectedIndex = 1,
    items = {
      { key = "male", rect = rect(10, 20, 30, 40), payload = { gender = 0 } },
      { key = "female", rect = rect(50, 20, 30, 40), payload = { gender = 1 } },
    },
  }
end

function T.resolved_items_are_the_single_geometry_authority_for_paint_and_hit_testing()
  local ChoiceGroup = choiceGroup()
  local group = ChoiceGroup.resolve(validSpec())
  local observations, commands = {}, {}
  local paintList = {
    image = function(_, key, itemRect)
      commands[#commands + 1] = { key = key, rect = itemRect }
    end,
  }

  ChoiceGroup.paint(group, paintList, function(list, item, selected, context)
    context[#context + 1] = {
      key = item.key,
      index = item.index,
      selected = selected,
      rect = item.rect,
      payload = item.payload,
    }
    list:image(item.key, item.rect)
  end, observations)

  Assert.equal(#observations, 2)
  Assert.equal(observations[1].key, "male")
  Assert.equal(observations[2].key, "female")
  Assert.equal(#commands, 2)
  Assert.equal(commands[1].key, "male")
  Assert.equal(commands[2].key, "female")
  Assert.deepEqual(commands[1].rect, group.items[0].rect)
  Assert.deepEqual(commands[2].rect, group.items[1].rect)
  Assert.deepEqual(observations[1].rect, commands[1].rect)
  Assert.deepEqual(observations[2].rect, commands[2].rect)
  Assert.deepEqual(
    observations[1],
    { key = "male", index = 0, selected = false, rect = rect(10, 20, 30, 40), payload = { gender = 0 } }
  )
  Assert.deepEqual(
    observations[2],
    { key = "female", index = 1, selected = true, rect = rect(50, 20, 30, 40), payload = { gender = 1 } }
  )
end

function T.hit_testing_uses_half_open_edges_and_leaves_gaps_unselected()
  local ChoiceGroup = choiceGroup()
  local group = ChoiceGroup.resolve({
    selectedIndex = 0,
    items = {
      { key = "left", rect = rect(10, 20, 30, 40) },
      { key = "right", rect = rect(50, 20, 30, 40) },
    },
  })

  Assert.equal(ChoiceGroup.hitTest(group, 10, 20), 0)
  Assert.equal(ChoiceGroup.hitTest(group, 39.999, 59.999), 0)
  Assert.equal(ChoiceGroup.hitTest(group, 50, 20), 1)
  Assert.equal(ChoiceGroup.hitTest(group, 79.999, 59.999), 1)
  Assert.isNil(ChoiceGroup.hitTest(group, 40, 30))
  Assert.isNil(ChoiceGroup.hitTest(group, 80, 30))
  Assert.isNil(ChoiceGroup.hitTest(group, 30, 60))
end

function T.resolver_rejects_invalid_items_indices_keys_rectangles_and_overlap()
  local ChoiceGroup = choiceGroup()
  local function rejects(spec)
    Assert.throws(function()
      ChoiceGroup.resolve(spec)
    end)
  end

  rejects({ selectedIndex = 0, items = {} })
  rejects({ selectedIndex = 0, items = { { key = "one" } } })
  rejects({ selectedIndex = 1, items = { { key = "one", rect = rect(0, 0, 1, 1) } } })
  rejects({ selectedIndex = 0.5, items = { { key = "one", rect = rect(0, 0, 1, 1) } } })
  rejects({
    selectedIndex = 0,
    items = { { key = "one", rect = rect(0, 0, 1, 1) }, { key = "one", rect = rect(2, 0, 1, 1) } },
  })
  rejects({
    selectedIndex = 0,
    items = { { key = "one", rect = rect(0, 0, 2, 2) }, { key = "two", rect = rect(1, 1, 2, 2) } },
  })
  rejects({ selectedIndex = 0, items = { { key = "one", rect = rect(0, 0, 0, 2) } } })
  rejects({ selectedIndex = 0, items = { { key = "one", rect = rect(0, 0, math.huge, 2) } } })
  rejects({ selectedIndex = 0, items = { { key = "", rect = rect(0, 0, 1, 1) } } })
end

return { tests = T }
