-- Real-context presentation fixtures verify the HGSS-inspired menu skin at
-- 4:3, wide, and portrait geometry. Pixel checks keep these smokes stable
-- without coupling them to host font rasterization.

local Assert = require("tests.support.Assert")
local FieldMenuController = require("libs.engine.src.FieldMenuController")
local FieldMenuRenderer = require("libs.engine.src.FieldMenuRenderer")
local FieldMenuTheme = require("libs.engine.src.FieldMenuTheme")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MenuLayout = require("libs.engine.src.MenuLayout")
local ScreenTopology = require("libs.engine.src.ScreenTopology")

local T = {}

local function fixture(width, height, count, touch)
  local items = {}
  for index = 1, count do
    items[index] = { text = "Choice " .. index, value = index }
  end
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = touch,
  })
  local layout = MenuLayout.resolve({
    topology = topology,
    menu = { items = items, cancellable = touch },
    measureText = function(text)
      return #text * 8
    end,
  })
  return layout, FieldMenuController.new({ items = items, cancellable = touch, cancelValue = touch and -1 or nil })
end

function T.default_theme_is_hgss_compact_and_opaque()
  Assert.equal(FieldMenuTheme.schema, "g4-field-menu-theme-v1")
  Assert.equal(FieldMenuTheme.colors.fill[4], 1)
  Assert.isTrue(FieldMenuTheme.textInsetX > 0)
end

function T.presentation_fixtures_draw_a_framed_menu_in_4_3_wide_and_portrait(scope)
  local renderer = FieldMenuRenderer.new()
  for _, case in ipairs({
    { width = 256, height = 192, count = 3, touch = false, presentation = "floating" },
    { width = 1280, height = 720, count = 3, touch = false, presentation = "floating" },
    { width = 390, height = 844, count = 8, touch = true, presentation = "docked" },
  }) do
    local layout, menu = fixture(case.width, case.height, case.count, case.touch)
    Assert.equal(layout.presentation, case.presentation)
    local canvas = scope:own(love.graphics.newCanvas(case.width, case.height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw(menu, layout)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    local x = math.floor(layout.frame.x + layout.frame.width / 2)
    local y = math.floor(layout.frame.y + layout.frame.height - 3)
    local r, g, b, a = image:getPixel(x, y)
    Assert.near(r, FieldMenuTheme.colors.fill[1], 0.06)
    Assert.near(g, FieldMenuTheme.colors.fill[2], 0.06)
    Assert.near(b, FieldMenuTheme.colors.fill[3], 0.06)
    Assert.near(a, 1, 0.01)
  end
end

return GraphicsSmoke.suite(T)
