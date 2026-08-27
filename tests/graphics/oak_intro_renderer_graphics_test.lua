local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local NewGame = require("libs.engine.src.NewGame")
local OakIntroController = require("libs.engine.src.OakIntroController")
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

local function genderSelector()
  local function mask(id)
    return { image = id .. ".png", width = 4, height = 4, bounds = { x = 0, y = 0, width = 4, height = 4 } }
  end
  return {
    neutral = { image = "gender-selector-neutral.png", width = 256, height = 192 },
    defaultTone = { r = 200, g = 200, b = 200 },
    buttons = {
      male = {
        bounds = { x = 0, y = 0, width = 4, height = 4 },
        pulseMask = mask("gender-selector-male-pulse"),
        accentMask = mask("gender-selector-male-accent"),
      },
      female = {
        bounds = { x = 0, y = 0, width = 4, height = 4 },
        pulseMask = mask("gender-selector-female-pulse"),
        accentMask = mask("gender-selector-female-accent"),
      },
    },
  }
end

local function manifest()
  local assets = {
    background = {
      image = "background.png",
      width = 1,
      height = 192,
      sampling = "linear",
      frames = { { image = "background.png", x = 0, y = 0, width = 1, height = 192, duration = 1 } },
    },
  }
  for _, id in ipairs({
    "oak",
    "marill",
    "marill_appear",
    "male",
    "female",
    "shrink_male",
    "shrink_female",
    "ball_open",
    "gender_background",
    "gender_male",
    "gender_female",
  }) do
    assets[id] = {
      image = id .. ".png",
      width = 4,
      height = 8,
      sampling = "nearest",
      frames = { { image = id .. ".png", x = 0, y = 0, width = 4, height = 8, duration = 1 } },
    }
  end
  assets.oak.frames = {
    { image = "oak.png", x = 0, y = 0, width = 4, height = 4, duration = 1 },
    { image = "oak.png", x = 0, y = 4, width = 4, height = 4, duration = 1 },
  }
  local background = assets.background
  assets.background = nil
  return { background = background, widgets = assets, genderSelector = genderSelector() }
end

local function view()
  return {
    phase = "oak_welcome",
    visual = "oak",
    visualFrameIndex = 2,
    sceneBrightness = 0,
    revealBrightness = 0,
    revealOpacity = 1,
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

local function backgroundOnlyController()
  local audio = {
    playMusic = function() end,
    stopMusic = function() end,
    fadeMusicOut = function() end,
    play = function() end,
    playCry = function() end,
    updateSoundFrame = function() end,
    isMusicFadeActive = function()
      return false
    end,
  }
  local controller = OakIntroController.new({
    candidate = NewGame.createCandidate({
      saveService = {
        reserve = function()
          return "graphics-acceptance"
        end,
      },
      versionId = "heartgold",
      eventState = FieldEventState.new(),
      scriptSymbols = FieldScriptSymbols,
      mapIdentity = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, sourceFacing = 1 },
    }),
    clock = {
      nowLocal = function()
        return { hour = 12, minute = 0 }
      end,
    },
    audio = audio --[[@as GameSound]],
    messages = {
      ["greeting.day"] = "greeting.day",
      ["oak.welcome"] = "oak.welcome",
      ["oak.world_inhabited"] = "oak.world_inhabited",
      ["oak.live_alongside"] = "oak.live_alongside",
      ["oak.tell_about_yourself"] = "oak.tell_about_yourself",
      ["profile.gender_question"] = "profile.gender_question",
    },
    assets = {
      marill = { frames = { { duration = 1 } } },
      marill_appear = { frames = { { duration = 1 } } },
      ball_open = { frames = { { duration = 1 } } },
    },
    virtualGlyphs = { "A" },
    playerDataContext = { charmap = { A = 1 }, frameIndexes = { [0] = true } },
    randomU32 = function()
      return 0x12345678
    end,
  })
  controller:start()
  controller:tick(40)
  return controller
end

T.responsive_renderer_uses_declared_sampling_and_identity_tint = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
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
  flash.sceneBrightness = 1
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

T.background_gradient_stretches_to_the_host_viewport = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
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
  local oakView = view()
  oakView.layout.viewport = { x = 13, y = 17, width = 1600, height = 900 }
  oakView.primaryWidget = "oak"

  renderer:draw(oakView)

  local background = graphics.draws[1]
  Assert.equal(background.x, 13)
  Assert.equal(background.y, 17)
  Assert.equal(background.sx, 1600)
  Assert.equal(background.sy, 900 / 192)
  Assert.equal(background.quad.w * background.sx, 1600)
  Assert.equal(background.quad.h * background.sy, 900)

  local widget = graphics.draws[2]
  Assert.equal(widget.sx, widget.sy)
  renderer:dispose()
end

T.gender_gradient_covers_the_full_viewport_not_a_composition_region = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
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
  local gender = view()
  gender.phase = "gender_select"
  gender.primaryWidget = nil
  gender.layout.viewport = { x = 11, y = 13, width = 1600, height = 900 }
  gender.layout.oakRegion = { x = 11, y = 13, width = 500, height = 900 }
  gender.layout.genderBackground = { x = 600, y = 100, width = 400, height = 300 }
  gender.layout.genderChoices = {
    [0] = { x = 600, y = 100, width = 100, height = 150 },
    [1] = { x = 800, y = 100, width = 100, height = 150 },
  }
  gender.layout.genderCanvas = { origin = { x = 600, y = 100 }, scale = 1 }
  gender.genderFocus = 0
  gender.focusBlinkDelta = 0

  renderer:draw(gender)

  local background = graphics.draws[1]
  Assert.equal(background.x, 11)
  Assert.equal(background.y, 13)
  Assert.equal(background.sx, 1600)
  Assert.equal(background.sy, 900 / 192)
  renderer:dispose()
end

T.background_only_view_draws_the_gradient_once_without_a_subject = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
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
  local controller = backgroundOnlyController()
  local background = controller:view() --[[@as table]]
  background.layout = view().layout

  renderer:draw(background)

  Assert.equal(#graphics.draws, 1, "background-only phases draw one image")
  Assert.equal(graphics.draws[1].image.path, "background.png")
  Assert.equal(graphics.draws[1].sx, 160)
  Assert.equal(graphics.draws[1].sy, 120 / 192)
  renderer:dispose()
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

function T.animated_frames_use_distinct_images_and_release_unique_paths()
  local graphics = FakeGraphics.new({
    imageSizes = { { 8, 8 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 } },
  })
  local manifestValue = manifest()
  manifestValue.widgets.oak.image = "oak-frame-1.png"
  manifestValue.widgets.oak.frames = {
    { image = "oak-frame-1.png", x = 0, y = 0, width = 4, height = 4, duration = 1 },
    { image = "oak-frame-2.png", x = 0, y = 0, width = 4, height = 4, duration = 1 },
    { image = "oak-frame-2.png", x = 0, y = 0, width = 4, height = 4, duration = 1 },
  }
  local renderer = OakIntroRenderer.new({
    manifest = manifestValue,
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
  })

  local first = view()
  first.visualFrameIndex = 1
  renderer:draw(first)
  local second = view()
  second.visualFrameIndex = 2
  renderer:draw(second)

  Assert.equal(graphics.draws[2].image.path, "oak-frame-1.png")
  Assert.equal(graphics.draws[4].image.path, "oak-frame-2.png")
  local loaded = {}
  for _, image in ipairs(graphics.images) do
    loaded[image.path] = (loaded[image.path] or 0) + 1
  end
  Assert.equal(loaded["oak-frame-1.png"], 1)
  Assert.equal(loaded["oak-frame-2.png"], 1)
  renderer:dispose()
  for _, image in ipairs(graphics.images) do
    Assert.isTrue(image.released)
  end
end

function T.image_construction_failure_releases_every_prior_image()
  local graphics = FakeGraphics.new({ failOnImageCall = 3 })
  local ok = pcall(function()
    OakIntroRenderer.new({
      manifest = manifest(),
      graphics = graphics,
      imageLoader = function()
        return graphics.newImage()
      end,
      text = textRenderer(),
    })
  end)
  Assert.isFalse(ok)
  Assert.equal(#graphics.images, 2)
  for _, image in ipairs(graphics.images) do
    Assert.isTrue(image.released)
  end
end

-- Gender focus must pulse the selected button-frame semantics, not tint the
-- portrait pixels themselves: both the male and female portrait draws must
-- keep an identity (untinted) color regardless of which one is focused.
T.gender_focus_leaves_portrait_draw_color_untinted = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
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
  local gender = view()
  gender.phase = "gender_select"
  gender.primaryWidget = nil
  gender.layout.genderBackground = { x = 0, y = 0, width = 160, height = 120, scale = 1 }
  gender.layout.genderChoices = {
    [0] = { x = 10, y = 10, width = 40, height = 60, scale = 1 },
    [1] = { x = 100, y = 10, width = 40, height = 60, scale = 1 },
  }
  gender.layout.genderCanvas = { origin = { x = 0, y = 0 }, scale = 1 }
  gender.genderFocus = 0
  gender.focusBlinkDelta = 8

  renderer:draw(gender)

  local maleColor, femaleColor
  for _, draw in ipairs(graphics.draws) do
    if draw.x == 10 then
      maleColor = draw.color
    elseif draw.x == 100 then
      femaleColor = draw.color
    end
  end
  Assert.notNil(maleColor, "male portrait must be drawn")
  Assert.notNil(femaleColor, "female portrait must be drawn")
  Assert.deepEqual(maleColor, { 1, 1, 1, 1 }, "focused portrait must not be recolored; only the selector frame pulses")
  Assert.deepEqual(femaleColor, { 1, 1, 1, 1 }, "unfocused portrait must not be recolored")
  renderer:dispose()
end

-- The renderer must actually consume C01's neutral surface/mask/default-tone
-- selector semantics to draw the source button-frame pulse; a manifest that
-- omits them cannot silently produce a working (but invisible) selector.
T.gender_selector_construction_requires_the_generated_frame_semantics = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
  })
  local manifestValue = manifest()
  manifestValue.genderSelector = nil
  local ok = pcall(function()
    OakIntroRenderer.new({
      manifest = manifestValue, -- lacks genderSelector: no neutral surface/pulseMask/accentMask/defaultTone
      graphics = graphics,
      imageLoader = function(path)
        local image = graphics.newImage()
        image.path = path
        return image
      end,
      text = textRenderer(),
    })
  end)
  Assert.isFalse(
    ok,
    "the renderer must require C01's genderSelector semantics to render the source frame pulse, not construct silently without them"
  )
end

return GraphicsSmoke.suite(T)
