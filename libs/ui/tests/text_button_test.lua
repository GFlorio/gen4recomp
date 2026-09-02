local Assert = require("tests.support.Assert")

---@diagnostic disable: missing-return-value

local T = {}

local function textButtonModule()
  local ok, mod = pcall(require, "libs.ui.src.TextButton")
  Assert.isTrue(ok, "TextButton missing: " .. tostring(mod))
  return mod
end

local function rect(x, y, w, h)
  return { x = x, y = y, width = w, height = h }
end

local function recordingGraphics()
  local state = { color = { 1, 1, 1, 1 }, lineWidth = 1 }
  local calls =
    { setColor = {}, rectangles = {}, polygons = {}, lineWidths = {}, transforms = {}, pushCount = 0, popCount = 0 }
  local g = {
    setColor = function(r, g2, b, a)
      state.color = { r, g2, b, a }
      calls.setColor[#calls.setColor + 1] = { r, g2, b, a }
    end,
    rectangle = function(mode, x, y, w, h, rx, ry)
      calls.rectangles[#calls.rectangles + 1] = {
        mode = mode,
        x = x,
        y = y,
        w = w,
        h = h,
        rx = rx,
        ry = ry,
        color = { state.color[1], state.color[2], state.color[3], state.color[4] },
        lineWidth = state.lineWidth,
      }
    end,
    polygon = function(mode, ...)
      calls.polygons[#calls.polygons + 1] =
        { mode = mode, points = { ... }, color = { state.color[1], state.color[2], state.color[3], state.color[4] } }
    end,
    setLineWidth = function(w)
      state.lineWidth = w
      calls.lineWidths[#calls.lineWidths + 1] = w
    end,
    getLineWidth = function()
      return state.lineWidth
    end,
    push = function()
      calls.pushCount = calls.pushCount + 1
    end,
    pop = function()
      calls.popCount = calls.popCount + 1
    end,
    translate = function(x, y)
      calls.transforms[#calls.transforms + 1] = { "translate", x, y }
    end,
    scale = function(x, y)
      calls.transforms[#calls.transforms + 1] = { "scale", x, y }
    end,
    getColor = function()
      return state.color[1], state.color[2], state.color[3], state.color[4]
    end,
    _calls = calls,
    _state = state,
  }
  return g, calls
end

function T.canonical_geometry_matches_yes_no_format()
  local TextButton = textButtonModule()
  local at1 = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  Assert.equal(at1.contentRect.x, 8)
  Assert.equal(at1.contentRect.y, 16)
  Assert.equal(at1.contentRect.width, 104)
  Assert.equal(at1.contentRect.height, 24)
  Assert.equal(at1.border.cornerCut, 2)
  Assert.equal(at1.rim.cornerCut, 0)
  Assert.equal(at1.face.cornerCut, 0)
  local at2 = TextButton.resolve({ rect = rect(0, 0, 240, 112), scale = 2 })
  Assert.equal(at2.contentRect.width, 208)
  Assert.equal(at2.contentRect.height, 48)
  Assert.equal(at2.border.cornerCut, 4)
end

function T.reference_dimensions_are_canonical()
  local TextButton = textButtonModule()
  Assert.equal(TextButton.REFERENCE_WIDTH, 120)
  Assert.equal(TextButton.REFERENCE_HEIGHT, 56)
end

function T.preserves_focus_and_supports_one_role_override()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(10, 20, 120, 56), scale = 1 })
  local g1, calls1 = recordingGraphics()
  local text1 = {
    measure = function()
      return 20
    end,
    lineHeight = 16,
    draw = function() end,
  }
  TextButton.draw(g1, button, { label = "Yes", selected = false, text = text1 })
  -- Unselected has no focus lines: only base draw, no lineWidth 5/3
  Assert.isTrue(#calls1.lineWidths == 0, "unselected has no focus lines")

  local g2, calls2 = recordingGraphics()
  local drawCalls = {}
  local text2 = {
    measure = function()
      return 20
    end,
    lineHeight = 16,
    draw = function(l, x, y)
      drawCalls[#drawCalls + 1] = { l, x, y }
    end,
  }
  TextButton.draw(g2, button, { label = "No", selected = true, text = text2 })
  Assert.equal(calls2.lineWidths[1], 5)
  Assert.equal(calls2.lineWidths[2], 3)
  Assert.equal(#drawCalls, 1)
  -- Focus rectangles are same inset/radius for white and red.
  Assert.equal(calls2.rectangles[#calls2.rectangles - 1].x, calls2.rectangles[#calls2.rectangles].x)
  Assert.equal(calls2.rectangles[#calls2.rectangles - 1].y, calls2.rectangles[#calls2.rectangles].y)

  -- Override only faceTop
  local g3, calls3 = recordingGraphics()
  local text3 = {
    measure = function()
      return 20
    end,
    lineHeight = 16,
    draw = function() end,
  }
  TextButton.draw(g3, button, { label = "Yes", selected = true, text = text3, colors = { faceTop = { 0, 0, 1, 1 } } })
  -- Base colors: check that only faceTop changed, others default. We can infer via setColor calls for base layers.
  -- First 5 setColors are base: border, rim, innerBorder, faceBottom, faceTop. faceTop should be blue.
  Assert.equal(calls3.setColor[5][3], 1)
  Assert.equal(calls3.setColor[1][1], 66 / 255)
end

function T.text_is_centered_and_callback_invoked_once()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  local drawPositions = {}
  local text = {
    measure = function()
      return 40
    end,
    lineHeight = 16,
    draw = function(_, x, y)
      drawPositions[#drawPositions + 1] = { x = x, y = y }
    end,
  }
  TextButton.draw(g, button, { label = "Yes", selected = false, text = text })
  Assert.equal(#drawPositions, 1)
  -- Content is 104x24 at (8,16). With local coords, centered should be around (8 + (104-40)/2, 16 + (24-16)/2)
  local expectedX = 8 + (104 - 40) / 2
  local expectedY = 16 + (24 - 16) / 2
  Assert.near(drawPositions[1].x, expectedX)
  Assert.near(drawPositions[1].y, expectedY)
  Assert.equal(g._calls.pushCount, 1)
  Assert.equal(g._calls.popCount, 1)
end

function T.unknown_color_keys_are_rejected()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  local text = {
    measure = function()
      return 10
    end,
    lineHeight = 16,
    draw = function() end,
  }
  Assert.throws(function()
    TextButton.draw(g, button, { label = "Yes", selected = false, text = text, colors = { unknown = { 1, 0, 0, 1 } } })
  end)
end

function T.invalid_scale_and_non_fitting_label_are_rejected()
  local TextButton = textButtonModule()
  Assert.throws(function()
    TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 0 })
  end)
  Assert.throws(function()
    TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = -1 })
  end)
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  Assert.throws(function()
    TextButton.draw(g, button, {
      label = "Yes",
      selected = false,
      text = {
        measure = function()
          return 200
        end,
        lineHeight = 16,
        draw = function() end,
      },
    })
  end)
  Assert.throws(function()
    TextButton.draw(g, button, {
      label = "Yes",
      selected = false,
      text = {
        measure = function()
          return 10
        end,
        lineHeight = 100,
        draw = function() end,
      },
    })
  end)
end

function T.callback_failure_restores_transform_stack()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  local text = {
    measure = function()
      return 10
    end,
    lineHeight = 16,
    draw = function()
      error("boom")
    end,
  }
  Assert.throws(function()
    TextButton.draw(g, button, { label = "Yes", selected = false, text = text })
  end)
  Assert.equal(g._calls.pushCount, g._calls.popCount)
end

return { tests = T }
