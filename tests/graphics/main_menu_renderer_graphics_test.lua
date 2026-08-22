-- Graphics smoke coverage for the Main Menu card viewport and caller-owned
-- scissor restoration.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MainMenuRenderer = require("game.src.game.MainMenuRenderer")

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

return GraphicsSmoke.suite(T)
