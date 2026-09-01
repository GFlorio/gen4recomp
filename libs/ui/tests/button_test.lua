-- Button tests cover pure geometry snapshots and half-open containment.

local Assert = require("tests.support.Assert")

local T = {}

local function buttonModule()
  local ok, moduleOrError = pcall(require, "libs.ui.src.Button")
  Assert.isTrue(ok, "Button geometry behavior is missing: " .. tostring(moduleOrError))
  return moduleOrError
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

---@param overrides table<string, number|boolean|table>|nil
---@return table<string, number|boolean|table>
local function spec(overrides)
  ---@type table<string, number|boolean|table>
  local result = {
    rect = rect(10, 20, 100, 60),
    bevelWidth = 4,
    contentInsetX = 6,
    contentInsetY = 5,
  }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

local function copyRect(value)
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function assertContained(inner, outer, label)
  Assert.isTrue(inner.x >= outer.x, label .. " must start inside the outer rectangle")
  Assert.isTrue(inner.y >= outer.y, label .. " must start inside the outer rectangle")
  Assert.isTrue(inner.x + inner.width <= outer.x + outer.width, label .. " must end inside the outer rectangle")
  Assert.isTrue(inner.y + inner.height <= outer.y + outer.height, label .. " must end inside the outer rectangle")
  Assert.isTrue(inner.width > 0, label .. " must have positive width")
  Assert.isTrue(inner.height > 0, label .. " must have positive height")
end

local function assertBevelEdges(button)
  for _, name in ipairs({ "top", "left", "bottom", "right" }) do
    Assert.notNil(button[name], name .. " bevel edge must be exposed")
    assertContained(button[name], button.rect, name .. " bevel edge")
  end
end

function T.valid_specs_resolve_contained_geometry_without_mutating_inputs()
  local Button = buttonModule()
  local input = spec()
  local resolved = Button.resolve(input)
  local snapshot = {
    rect = copyRect(resolved.rect),
    faceRect = copyRect(resolved.faceRect),
    contentRect = copyRect(resolved.contentRect),
    top = copyRect(resolved.top),
    left = copyRect(resolved.left),
    bottom = copyRect(resolved.bottom),
    right = copyRect(resolved.right),
  }

  Assert.deepEqual(resolved.rect, input.rect)
  Assert.equal(resolved.top.height, input.bevelWidth)
  Assert.equal(resolved.left.width, input.bevelWidth)
  Assert.equal(resolved.bottom.height, input.bevelWidth)
  Assert.equal(resolved.right.width, input.bevelWidth)
  Assert.equal(resolved.faceRect.x, input.rect.x + input.bevelWidth)
  Assert.equal(resolved.faceRect.y, input.rect.y + input.bevelWidth)
  Assert.equal(resolved.contentRect.x, resolved.faceRect.x + input.contentInsetX)
  Assert.equal(resolved.contentRect.y, resolved.faceRect.y + input.contentInsetY)
  assertContained(resolved.faceRect, resolved.rect, "face rectangle")
  assertContained(resolved.contentRect, resolved.faceRect, "content rectangle")
  assertBevelEdges(resolved)

  input.rect.x = 900
  input.rect.y = 901
  input.rect.width = 902
  input.rect.height = 903
  input.bevelWidth = 20
  input.contentInsetX = 21
  input.contentInsetY = 22

  Assert.deepEqual(resolved.rect, snapshot.rect)
  Assert.deepEqual(resolved.faceRect, snapshot.faceRect)
  Assert.deepEqual(resolved.contentRect, snapshot.contentRect)
  Assert.deepEqual(resolved.top, snapshot.top)
  Assert.deepEqual(resolved.left, snapshot.left)
  Assert.deepEqual(resolved.bottom, snapshot.bottom)
  Assert.deepEqual(resolved.right, snapshot.right)
end

function T.containment_is_half_open_and_invalid_geometry_is_rejected()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ rect = rect(10, 20, 30, 40), bevelWidth = 2 }))

  Assert.isTrue(Button.contains(resolved, 10, 20))
  Assert.isTrue(Button.contains(resolved, 39.999, 59.999))
  Assert.isFalse(Button.contains(resolved, 40, 30))
  Assert.isFalse(Button.contains(resolved, 30, 60))

  local flat = Button.resolve(spec({ rect = rect(10, 20, 30, 40), bevelWidth = 0 }))
  Assert.isTrue(flat.faceRect.width > 0 and flat.faceRect.height > 0)
  Assert.isTrue(flat.contentRect.width > 0 and flat.contentRect.height > 0)

  local function rejects(candidate)
    Assert.throws(function()
      Button.resolve(candidate)
    end)
  end

  for _, invalidRect in ipairs({
    { x = "10", y = 20, width = 30, height = 40 },
    { x = 10, y = math.huge, width = 30, height = 40 },
    { x = 10, y = 20, width = 0, height = 40 },
    { x = 10, y = 20, width = -1, height = 40 },
    { x = 10, y = 20, width = 30, height = 0 / 0 },
  }) do
    rejects(spec({ rect = invalidRect }))
  end

  for _, metric in ipairs({ false, -1, math.huge, -math.huge, 0 / 0 }) do
    rejects(spec({ bevelWidth = metric }))
    rejects(spec({ contentInsetX = metric }))
    rejects(spec({ contentInsetY = metric }))
  end
  rejects(spec({ bevelWidth = 50 }))
  rejects(spec({ contentInsetX = 46 }))
  rejects(spec({ contentInsetY = 26 }))
  rejects(spec({ rect = rect(math.huge * 0.75, 20, math.huge * 0.5, 40) }))

  for _, point in ipairs({
    { x = "10", y = 20 },
    { x = math.huge, y = 20 },
    { x = 10, y = 0 / 0 },
  }) do
    Assert.throws(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      Button.contains(resolved, point.x, point.y)
    end)
  end
end

return { tests = T }
