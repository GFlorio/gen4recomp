local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local OakIntroRenderer = require("game.src.game.OakIntroRenderer")

local T = {}

local function textRenderer()
  return {
    drawText = function() end,
    textWidth = function(_, text)
      return #text * 8
    end,
  }
end

local function manifest()
  local assets = {
    background = {
      image = "background.png",
      width = 8,
      height = 8,
      sampling = "linear",
      frames = { { x = 0, y = 0, width = 8, height = 8, duration = 1 } },
    },
  }
  for _, id in ipairs({ "oak", "marill", "male", "female", "shrink_male", "shrink_female", "ball_open" }) do
    assets[id] = {
      image = id .. ".png",
      width = 4,
      height = 8,
      sampling = "nearest",
      frames = { { x = 0, y = 0, width = 4, height = 8, duration = 1 } },
    }
  end
  assets.oak.frames = {
    { x = 0, y = 0, width = 4, height = 4, duration = 1 },
    { x = 0, y = 4, width = 4, height = 4, duration = 1 },
  }
  local background = assets.background
  assets.background = nil
  return { background = background, widgets = assets }
end

local function view()
  return {
    phase = "oak_welcome",
    visual = "oak",
    visualFrameIndex = 2,
    flashAlpha = 0,
    message = nil,
    name = "",
    layout = {
      viewport = { x = 0, y = 0, width = 160, height = 120 },
      subject = { x = 20, y = 10, width = 80, height = 80 },
      cards = {},
      message = { x = 0, y = 0, width = 1, height = 1 },
      nameGrid = {},
      nameKeys = {},
    },
  }
end

T.responsive_renderer_uses_declared_sampling_and_identity_tint = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 8, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
  })
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
  })
  local normal = view()
  normal.primaryWidget = "oak"
  renderer:draw(normal)
  local flash = view()
  flash.primaryWidget = "oak"
  flash.flashAlpha = 1
  renderer:draw(flash)

  Assert.equal(#graphics.draws, 4, "each frame draws background and Oak exactly once")
  for _, draw in ipairs(graphics.draws) do
    Assert.deepEqual(draw.color, { 1, 1, 1, 1 }, "image draws must use identity tint")
  end
  local filters = {}
  for _, image in ipairs(graphics.images) do
    filters[image.path] = image.filters[1]
  end
  Assert.equal(filters["background.png"].min, "linear")
  Assert.equal(filters["background.png"].mag, "linear")
  Assert.equal(filters["oak.png"].min, "nearest")
  Assert.equal(filters["oak.png"].mag, "nearest")
  renderer:dispose()
  for _, image in ipairs(graphics.images) do
    Assert.isTrue(image.released)
  end
end

function T.nonzero_atlas_frame_is_drawn_with_a_reusable_quad(scope)
  local graphics = FakeGraphics.new({ imageSizes = { { 8, 8 }, { 4, 8 } } })
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(path)
      return graphics.newImage()
    end,
    text = textRenderer(),
  })
  renderer:draw(view())
  Assert.equal(#graphics.draws, 2)
  Assert.equal(graphics.draws[2].quad.y, 4)
  Assert.equal(graphics.draws[2].x, 20)
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
      text = textRenderer(),
    })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil)
  for _, image in ipairs(graphics.images) do
    Assert.isTrue(image.released)
  end
end

return GraphicsSmoke.suite(T)
