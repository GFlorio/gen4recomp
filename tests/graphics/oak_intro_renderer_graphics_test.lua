local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local OakIntroRenderer = require("game.src.game.OakIntroRenderer")

local T = {}

local function manifest()
  return {
    assets = {
      background = {
        image = "background.png",
        width = 8,
        height = 8,
        frames = { { x = 0, y = 0, width = 8, height = 8, duration = 1 } },
      },
      oak = {
        image = "oak.png",
        width = 4,
        height = 8,
        frames = {
          { x = 0, y = 0, width = 4, height = 4, duration = 1 },
          { x = 0, y = 4, width = 4, height = 4, duration = 1 },
        },
      },
    },
  }
end

local function view()
  return {
    phase = "oak_welcome",
    visual = "oak",
    visualFrameIndex = 2,
    oakOffsetX = 7,
    flashAlpha = 0,
    message = nil,
    name = "",
    layout = {
      viewport = { x = 0, y = 0, width = 160, height = 120 },
      subject = { x = 20, y = 10, width = 80, height = 80 },
      cards = {},
      message = { x = 0, y = 0, width = 1, height = 1 },
      nameGrid = {},
    },
  }
end

function T.nonzero_atlas_frame_is_drawn_with_a_reusable_quad(scope)
  local graphics = FakeGraphics.new({ imageSizes = { { 8, 8 }, { 4, 8 } } })
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(path)
      return graphics.newImage()
    end,
  })
  renderer:draw(view())
  Assert.equal(#graphics.draws, 2)
  Assert.equal(graphics.draws[2].quad.y, 4)
  Assert.equal(graphics.draws[2].x, 27)
  renderer:dispose()
  renderer:dispose()
end

function T.constructor_releases_images_when_quad_creation_fails()
  local graphics = FakeGraphics.new({ failOnQuadCall = 2, imageSizes = { { 8, 8 }, { 4, 8 } } })
  local ok, err = pcall(function()
    OakIntroRenderer.new({
      manifest = manifest(),
      graphics = graphics,
      imageLoader = function(path)
        return graphics.newImage()
      end,
    })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil)
  for _, image in ipairs(graphics.images) do
    Assert.isTrue(image.released)
  end
end

return GraphicsSmoke.suite(T)
