-- Graphics smoke coverage for the Main Menu card viewport and caller-owned
-- scissor restoration.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MainMenuRenderer = require("game.hgss.src.menu.MainMenuRenderer")

local T = {}

function T.cards_are_clipped_to_the_content_viewport_and_scissor_is_restored(scope)
  local content = { x = 16, y = 48, width = 128, height = 16 }
  local view = {
    focusedId = "new-game",
    items = { { id = "new-game", canContinue = true, canDelete = false } },
    layout = {
      viewport = { x = 0, y = 0, width = 160, height = 80 },
      content = content,
      cards = {
        ["new-game"] = { body = { x = 16, y = 48, width = 128, height = 44 } },
      },
    },
  }
  Assert.isTrue(view.layout.cards["new-game"].body.y + 44 > content.y + content.height)

  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 80))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  lg.setScissor(0, 0, 160, 80)

  local renderer = MainMenuRenderer.new()
  renderer:draw(view)

  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, 0)
  Assert.equal(sy, 0)
  Assert.equal(sw, 160)
  Assert.equal(sh, 80)

  lg.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local r, g, b = pixels:getPixel(20, math.floor(content.y + content.height + 4))
  Assert.near(r, 0.08, 1 / 255)
  Assert.near(g, 0.1, 1 / 255)
  Assert.near(b, 0.15, 1 / 255)
end

function T.catalog_errors_are_drawn_inside_the_layout_error_rectangle(scope)
  local errorRect = { x = 16, y = 48, width = 128, height = 24 }
  local view = {
    catalogError = "catalog unreadable",
    focusedId = "new-game",
    items = { { id = "new-game", canContinue = true, canDelete = false } },
    layout = {
      viewport = { x = 0, y = 0, width = 160, height = 100 },
      content = { x = 16, y = 48, width = 128, height = 44 },
      catalogErrorRect = errorRect,
      cards = {
        ["new-game"] = { body = { x = 16, y = 80, width = 128, height = 44 } },
      },
    },
  }

  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 100))
  lg.setCanvas(canvas)
  lg.clear(0.08, 0.1, 0.15, 1)
  local renderer = MainMenuRenderer.new()
  renderer:draw(view)
  lg.setCanvas()

  local pixels = scope:own(canvas:newImageData())
  local foundErrorPixel = false
  for y = errorRect.y, errorRect.y + errorRect.height - 1 do
    for x = errorRect.x, errorRect.x + errorRect.width - 1 do
      local r, g, b, a = pixels:getPixel(x, y)
      if a > 0 and r > g and r > b then
        foundErrorPixel = true
      end
    end
  end
  Assert.isTrue(foundErrorPixel, "catalog error text must draw inside its returned rectangle")
end

return GraphicsSmoke.suite(T)
