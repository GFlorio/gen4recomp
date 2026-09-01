-- Button tests cover pure layered geometry snapshots and half-open containment.

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

---@param overrides table<string, number|boolean|table|string>|nil
---@return table<string, number|boolean|table|string>
local function spec(overrides)
  ---@type table<string, number|boolean|table|string>
  local result = {
    rect = rect(10, 20, 100, 60),
    borderWidth = 2,
    rimWidth = 3,
    innerBorderWidth = 1,
    cornerCut = 6,
    faceSplit = 0.4,
    contentInsetX = 4,
    contentInsetY = 3,
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

local function snapshot(button)
  return {
    rect = copyRect(button.rect),
    border = { rect = copyRect(button.border.rect), cornerCut = button.border.cornerCut },
    rim = { rect = copyRect(button.rim.rect), cornerCut = button.rim.cornerCut },
    innerBorder = { rect = copyRect(button.innerBorder.rect), cornerCut = button.innerBorder.cornerCut },
    face = {
      rect = copyRect(button.face.rect),
      cornerCut = button.face.cornerCut,
      splitY = button.face.splitY,
    },
    contentRect = copyRect(button.contentRect),
  }
end

local function assertLayeredGeometry(button)
  Assert.keySet(button, "border,contentRect,face,innerBorder,rect,rim")
  local layers = { "border", "rim", "innerBorder", "face" }
  local parent = button.rect
  local previousCut = math.huge
  for _, name in ipairs(layers) do
    local layer = button[name]
    Assert.keySet(layer, name == "face" and "cornerCut,rect,splitY" or "cornerCut,rect", name .. " shape")
    assertContained(layer.rect, parent, name .. " shape")
    Assert.isTrue(layer.cornerCut >= 0, name .. " corner cut must be non-negative")
    Assert.isTrue(layer.cornerCut <= previousCut, name .. " corner cut must not grow inward")
    previousCut = layer.cornerCut
    parent = layer.rect
  end
  Assert.isTrue(button.face.splitY > button.face.rect.y, "face split must be below the face top")
  Assert.isTrue(
    button.face.splitY < button.face.rect.y + button.face.rect.height,
    "face split must be above the face bottom"
  )
  assertContained(button.contentRect, button.face.rect, "content rectangle")
end

function T.valid_specs_resolve_nested_geometry_without_mutating_inputs()
  local Button = buttonModule()
  local input = spec()
  local resolved = Button.resolve(input)
  local saved = snapshot(resolved)

  Assert.isTrue(resolved.rect ~= input.rect, "the resolved outer rectangle must be copied")
  Assert.equal(resolved.rim.rect.x, input.rect.x + input.borderWidth)
  Assert.equal(resolved.innerBorder.rect.x, input.rect.x + input.borderWidth + input.rimWidth)
  Assert.equal(resolved.face.rect.x, input.rect.x + input.borderWidth + input.rimWidth + input.innerBorderWidth)
  Assert.equal(resolved.contentRect.x, resolved.face.rect.x + input.contentInsetX)
  Assert.equal(resolved.contentRect.y, resolved.face.rect.y + input.contentInsetY)
  Assert.equal(resolved.border.cornerCut, 6)
  Assert.equal(resolved.rim.cornerCut, 4)
  Assert.equal(resolved.innerBorder.cornerCut, 1)
  Assert.equal(resolved.face.cornerCut, 0)
  Assert.near(resolved.face.splitY, resolved.face.rect.y + resolved.face.rect.height * input.faceSplit)
  assertLayeredGeometry(resolved)

  input.rect.x = 900
  input.rect.y = 901
  input.rect.width = 902
  input.rect.height = 903
  input.borderWidth = 20
  input.rimWidth = 21
  input.innerBorderWidth = 22
  input.cornerCut = 23
  input.faceSplit = 0.7
  input.contentInsetX = 24
  input.contentInsetY = 25

  Assert.deepEqual(resolved, saved)
end

function T.zero_width_layers_and_zero_corner_use_positive_rectangles()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({
    borderWidth = 0,
    rimWidth = 0,
    innerBorderWidth = 0,
    cornerCut = 0,
    contentInsetX = 2,
    contentInsetY = 2,
  }))

  assertLayeredGeometry(resolved)
  Assert.deepEqual(resolved.border.rect, resolved.rect)
  Assert.deepEqual(resolved.rim.rect, resolved.rect)
  Assert.deepEqual(resolved.innerBorder.rect, resolved.rect)
  Assert.deepEqual(resolved.face.rect, resolved.rect)
  Assert.equal(resolved.face.cornerCut, 0)
end

function T.containment_is_half_open_and_cut_corners_remain_hittable()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ rect = rect(10, 20, 30, 40), cornerCut = 4 }))

  Assert.isTrue(Button.contains(resolved, 10, 20))
  Assert.isTrue(Button.contains(resolved, 10.5, 20.5), "visible corner cuts must not change the hit rectangle")
  Assert.isTrue(Button.contains(resolved, 39.999, 59.999))
  Assert.isFalse(Button.contains(resolved, 40, 30))
  Assert.isFalse(Button.contains(resolved, 30, 60))

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

function T.invalid_metrics_and_collapsed_geometry_are_rejected()
  local Button = buttonModule()
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

  for _, metricName in ipairs({
    "borderWidth",
    "rimWidth",
    "innerBorderWidth",
    "cornerCut",
    "contentInsetX",
    "contentInsetY",
  }) do
    for _, value in ipairs({ false, "1", -1, math.huge, -math.huge, 0 / 0 }) do
      rejects(spec({ [metricName] = value }))
    end
  end

  for _, value in ipairs({ false, "0.5", 0, 1, -0.1, 1.1, math.huge, -math.huge, 0 / 0 }) do
    rejects(spec({ faceSplit = value }))
  end

  rejects(spec({ rect = rect(10, 20, 20, 10), cornerCut = 6 }))
  rejects(spec({ rect = rect(10, 20, 10, 10), borderWidth = 2, rimWidth = 2, innerBorderWidth = 2 }))
  rejects(spec({ rect = rect(10, 20, 20, 20), borderWidth = 1, rimWidth = 1, innerBorderWidth = 1, contentInsetX = 7 }))
  rejects(spec({ rect = rect(10, 20, 20, 20), borderWidth = 1, rimWidth = 1, innerBorderWidth = 1, contentInsetY = 7 }))
end

return { tests = T }
