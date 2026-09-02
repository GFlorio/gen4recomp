local Assert = require("tests.support.Assert")

local T = {}

local function buttonModule()
  local ok, mod = pcall(require, "libs.ui.src.Button")
  Assert.isTrue(ok, "Button missing: " .. tostring(mod))
  return mod
end

local function rect(x, y, w, h)
  return { x = x, y = y, width = w, height = h }
end

local function spec(overrides)
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
  for k, v in pairs(overrides or {}) do
    result[k] = v
  end
  return result
end

local function copyRect(v)
  return { x = v.x, y = v.y, width = v.width, height = v.height }
end

local function assertContained(inner, outer, label)
  Assert.isTrue(inner.x >= outer.x, label .. " start inside outer")
  Assert.isTrue(inner.y >= outer.y, label .. " start inside outer")
  Assert.isTrue(inner.x + inner.width <= outer.x + outer.width, label .. " end inside outer")
  Assert.isTrue(inner.y + inner.height <= outer.y + outer.height, label .. " end inside outer")
  Assert.isTrue(inner.width > 0, label .. " positive width")
  Assert.isTrue(inner.height > 0, label .. " positive height")
end

local function snapshot(b)
  return {
    rect = copyRect(b.rect),
    border = { rect = copyRect(b.border.rect), cornerCut = b.border.cornerCut },
    rim = { rect = copyRect(b.rim.rect), cornerCut = b.rim.cornerCut },
    innerBorder = { rect = copyRect(b.innerBorder.rect), cornerCut = b.innerBorder.cornerCut },
    face = { rect = copyRect(b.face.rect), cornerCut = b.face.cornerCut, splitY = b.face.splitY },
    contentRect = copyRect(b.contentRect),
  }
end

local function assertLayered(b)
  Assert.keySet(b, "border,contentRect,face,innerBorder,rect,rim")
  local layers = { "border", "rim", "innerBorder", "face" }
  local parent = b.rect
  local prev = math.huge
  for _, name in ipairs(layers) do
    local layer = b[name]
    Assert.keySet(layer, name == "face" and "cornerCut,rect,splitY" or "cornerCut,rect", name)
    assertContained(layer.rect, parent, name)
    Assert.isTrue(layer.cornerCut >= 0, name .. " cut non-negative")
    Assert.isTrue(layer.cornerCut <= prev, name .. " cut not grow inward")
    prev = layer.cornerCut
    parent = layer.rect
  end
  Assert.isTrue(b.face.splitY > b.face.rect.y, "split below top")
  Assert.isTrue(b.face.splitY < b.face.rect.y + b.face.rect.height, "split above bottom")
  assertContained(b.contentRect, b.face.rect, "content")
end

function T.valid_specs_resolve_nested_geometry_without_mutating_inputs()
  local Button = buttonModule()
  local input = spec()
  local resolved = Button.resolve(input)
  local saved = snapshot(resolved)
  Assert.isTrue(resolved.rect ~= input.rect, "resolved rect copied")
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
  assertLayered(resolved)
  input.rect.x = 900
  input.borderWidth = 20
  Assert.deepEqual(resolved, saved)
end

function T.zero_width_layers_and_zero_corner_use_positive_rectangles()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ borderWidth = 0, rimWidth = 0, innerBorderWidth = 0, cornerCut = 0, contentInsetX = 2, contentInsetY = 2 }))
  assertLayered(resolved)
  Assert.deepEqual(resolved.border.rect, resolved.rect)
  Assert.deepEqual(resolved.rim.rect, resolved.rect)
  Assert.deepEqual(resolved.innerBorder.rect, resolved.rect)
  Assert.equal(resolved.face.cornerCut, 0)
end

function T.containment_is_half_open_and_cut_corners_remain_hittable()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ rect = rect(10, 20, 30, 40), cornerCut = 4 }))
  Assert.isTrue(Button.contains(resolved, 10, 20))
  Assert.isTrue(Button.contains(resolved, 10.5, 20.5))
  Assert.isTrue(Button.contains(resolved, 39.999, 59.999))
  Assert.isFalse(Button.contains(resolved, 40, 30))
  Assert.isFalse(Button.contains(resolved, 30, 60))
end

function T.invalid_metrics_are_rejected()
  local Button = buttonModule()
  local function rejects(candidate)
    Assert.throws(function()
      Button.resolve(candidate)
    end)
  end
  for _, r in ipairs({ { x = "10", y = 20, width = 30, height = 40 }, { x = 10, y = 20, width = 0, height = 40 } }) do
    rejects(spec({ rect = r }))
  end
  for _, name in ipairs({ "borderWidth", "rimWidth", "innerBorderWidth", "cornerCut", "contentInsetX", "contentInsetY" }) do
    rejects(spec({ [name] = -1 }))
    rejects(spec({ [name] = math.huge }))
  end
  rejects(spec({ faceSplit = 0 }))
  rejects(spec({ faceSplit = 1 }))
  rejects(spec({ rect = rect(10, 20, 20, 10), cornerCut = 6 }))
  rejects(spec({ rect = rect(10, 20, 10, 10), borderWidth = 2, rimWidth = 2, innerBorderWidth = 2 }))
end

function T.draw_uses_cut_polygons_and_face_split()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ rect = rect(0, 0, 100, 60), cornerCut = 4 }))
  local calls = {}
  local graphics = {
    setColor = function(r, g, b, a)
      calls[#calls + 1] = { kind = "setColor", color = { r, g, b, a } }
    end,
    rectangle = function(mode, x, y, w, h)
      calls[#calls + 1] = { kind = "rectangle", mode = mode, x = x, y = y, w = w, h = h }
    end,
    polygon = function(mode, ...)
      calls[#calls + 1] = { kind = "polygon", mode = mode, points = { ... } }
    end,
  }
  local palette = {
    border = { 1, 0, 0, 1 },
    rim = { 0, 1, 0, 1 },
    innerBorder = { 0, 0, 1, 1 },
    faceTop = { 0.5, 0.5, 0.5, 1 },
    faceBottom = { 0.2, 0.2, 0.2, 1 },
  }
  Button.draw(graphics, resolved, palette)
  -- Should have 5 draw calls: border, rim, innerBorder, face bottom, face top polygon.
  Assert.equal(calls[1].kind, "setColor")
  -- Check that at least one polygon was used for cut corners.
  local hasPolygon = false
  for _, c in ipairs(calls) do
    if c.kind == "polygon" then
      hasPolygon = true
    end
  end
  Assert.isTrue(hasPolygon, "cut corners use polygon")
end

function T.draw_with_zero_corner_uses_rectangles()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ cornerCut = 0 }))
  local primitives = {}
  local graphics = {
    setColor = function() end,
    rectangle = function(mode)
      primitives[#primitives + 1] = mode
    end,
    polygon = function(mode)
      primitives[#primitives + 1] = "polygon:" .. mode
    end,
  }
  local palette = {
    border = { 1, 0, 0, 1 },
    rim = { 0, 1, 0, 1 },
    innerBorder = { 0, 0, 1, 1 },
    faceTop = { 0.5, 0.5, 0.5, 1 },
    faceBottom = { 0.2, 0.2, 0.2, 1 },
  }
  Button.draw(graphics, resolved, palette)
  for _, p in ipairs(primitives) do
    Assert.isTrue(p ~= "polygon:fill", "zero cut should use rectangles")
  end
end

return { tests = T }
