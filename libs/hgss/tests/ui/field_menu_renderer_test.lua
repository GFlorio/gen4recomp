-- Presentation-unit tests keep the menu renderer isolated from script and
-- message infrastructure while exercising its state restoration on failure.

local Assert = require("tests.support.Assert")
local FieldMenuController = require("libs.hgss.src.ui.FieldMenuController")
local FieldMenuRenderer = require("libs.hgss.src.ui.FieldMenuRenderer")
local MenuLayout = require("libs.hgss.src.ui.MenuLayout")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function fakeGraphics(opts)
  opts = opts or {}
  local calls = {}
  local color = { 0.2, 0.4, 0.6, 0.8 }
  local scissor = { 1, 2, 3, 4 }
  return {
    calls = calls,
    getColor = function()
      return color[1], color[2], color[3], color[4]
    end,
    setColor = function(r, g, b, a)
      color = { r, g, b, a }
    end,
    getScissor = function()
      return scissor[1], scissor[2], scissor[3], scissor[4]
    end,
    setShader = function(_) end,
    setWireframe = function(_) end,
    translate = function(_, _) end,
    setScissor = function(x, y, width, height)
      scissor = x and { x, y, width, height } or nil
    end,
    rectangle = function(mode, x, y, width, height)
      calls[#calls + 1] = { kind = "rectangle", mode = mode, x = x, y = y, width = width, height = height }
      if opts.failRectangle then
        error("injected rectangle failure")
      end
    end,
    print = function(text, x, y)
      calls[#calls + 1] = { kind = "text", text = text, x = x, y = y }
    end,
    polygon = function(mode, ...)
      calls[#calls + 1] = { kind = "polygon", mode = mode, points = { ... } }
    end,
  }
end

local function layout(count, cancellable, selectedIndex)
  local items = {}
  for index = 1, count do
    items[index] = { text = "Option " .. index, value = index }
  end
  return MenuLayout.resolve({
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      role = "world",
      touch = cancellable,
    }),
    menu = { items = items, cancellable = cancellable, selectedIndex = selectedIndex or 0 },
    measureText = function(text)
      return #text * 8
    end,
  }),
    items
end

local function controller(items, cancellable, initialCursor)
  return FieldMenuController.new({
    items = items,
    cancellable = cancellable,
    cancelValue = cancellable and -1 or nil,
    initialCursor = initialCursor,
  })
end

function T.draws_only_the_resolved_visible_rows_with_selection_scroll_and_cancel_affordances()
  local resolved, items = layout(20, true, 19)
  local menu = controller(items, true, 19)
  local graphics = fakeGraphics()

  FieldMenuRenderer.new({ graphics = graphics }):draw({ status = menu:status(), layout = resolved })

  local texts, selected, cancel, indicators = 0, 0, 0, 0
  for _, call in ipairs(graphics.calls) do
    if call.kind == "text" then
      texts = texts + 1
    elseif call.kind == "rectangle" and call.mode == "fill" and call.y == resolved.itemRects[19].y then
      selected = selected + 1
    elseif
      call.kind == "rectangle"
      and call.mode == "line"
      and resolved.cancelRect
      and call.y == resolved.cancelRect.y
    then
      cancel = cancel + 1
    elseif call.kind == "polygon" then
      indicators = indicators + 1
    end
  end
  Assert.isTrue(texts < 20, "clipped rows must not be drawn")
  Assert.equal(selected, 1, "the controller selection gets exactly one highlight")
  Assert.equal(cancel, 1, "the layout-owned cancel affordance is drawn")
  Assert.equal(indicators, 2, "a scrolled list shows both scroll indicators")
end

function T.draws_a_presentation_status_snapshot_without_a_controller()
  local resolved = layout(2, false)
  local graphics = fakeGraphics()

  FieldMenuRenderer.new({ graphics = graphics }):draw({ status = { selectedIndex = 1 }, layout = resolved })

  local highlighted = 0
  for _, call in ipairs(graphics.calls) do
    if call.kind == "rectangle" and call.mode == "fill" and call.y == resolved.itemRects[1].y then
      highlighted = highlighted + 1
    end
  end
  Assert.equal(highlighted, 1)
end

function T.rejects_a_presentation_selection_outside_the_resolved_layout()
  local resolved = layout(2, false)
  local graphics = fakeGraphics()

  local err = Assert.throws(function()
    FieldMenuRenderer.new({ graphics = graphics }):draw({ status = { selectedIndex = 2 }, layout = resolved })
  end)

  Assert.isTrue(tostring(err):find("field menu selected index is outside the resolved layout", 1, true) ~= nil)
end

function T.draw_failure_restores_color_and_scissor()
  local resolved, items = layout(2, false)
  local graphics = fakeGraphics({ failRectangle = true })
  local err = Assert.throws(function()
    local menu = controller(items, false)
    FieldMenuRenderer.new({ graphics = graphics }):draw({ status = menu:status(), layout = resolved })
  end)
  Assert.isTrue(tostring(err):find("injected rectangle failure", 1, true) ~= nil)
  local r, g, b, a = graphics.getColor()
  Assert.deepEqual({ r, g, b, a }, { 0.2, 0.4, 0.6, 0.8 })
  Assert.deepEqual({ graphics.getScissor() }, { 1, 2, 3, 4 })
end

function T.draws_zero_based_layout_rows_in_visual_order()
  local resolved, items = layout(3, false)
  local graphics = fakeGraphics()

  local menu = controller(items, false)
  FieldMenuRenderer.new({ graphics = graphics }):draw({ status = menu:status(), layout = resolved })

  local texts = {}
  for _, call in ipairs(graphics.calls) do
    if call.kind == "text" then
      texts[#texts + 1] = call.text
    end
  end
  Assert.deepEqual(texts, { "Option 1", "Option 2", "Option 3" })
end

return { tests = T }
