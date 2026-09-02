-- Final-pixel checks for the host-rendered gender controls and source portraits.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local IntroAssetCache = require("libs.assets.src.IntroAssetCache")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local function textRenderer()
  return {
    drawText = function() end,
    textWidth = function(_, value)
      return #value * 8
    end,
  }
end

local function choiceTextRenderer()
  local renderer = textRenderer()
  renderer.fontDef = { lineHeight = 16, palette = {} }
  for slot = 1, 16 do
    renderer.fontDef.palette[slot] = { r = 1, g = 1, b = 1 }
  end
  renderer.drawTextWithPalette = function() end
  return renderer
end

local function readyManifests()
  local result = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cache = CacheFs.forVersion(versionId)
      local manifest = assert(cache:loadLua(IntroAssetCache.manifestPath()))
      Assert.isTrue(IntroAssetCache.validateManifest(manifest), versionId .. " intro manifest is invalid")
      result[#result + 1] = { cache = cache, manifest = manifest, versionId = versionId }
    end
  end
  Assert.isTrue(#result > 0, "derived-cache capability promised a ready game version")
  return result
end

local function newImage(cache, path)
  local bytes = assert(cache:read(path), "missing generated image " .. path)
  local image = love.graphics.newImage(love.filesystem.newFileData(bytes, path), { linear = false, mipmaps = false })
  image:setFilter("nearest", "nearest")
  return image
end

local function rendererFor(scope, cache, manifest)
  local renderer = OakIntroRenderer.new({
    manifest = manifest,
    imageLoader = function(path)
      return newImage(cache, path)
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  return renderer
end

local function selectorView(manifest, width, height, focus, delta)
  local view = {
    phase = "gender_select",
    visual = "background",
    visualFrameIndex = 1,
    primaryWidget = nil,
    revealWidget = nil,
    revealFrameIndex = 1,
    revealBrightness = 0,
    revealOpacity = 1,
    sceneBrightness = 0,
    finalFadeAlpha = 0,
    message = nil,
    messageKey = nil,
    name = "",
    genderFocus = focus or 0,
    genderCompositionProgress = 1,
    focusBlinkDelta = delta or 0,
  }
  view.layout = OakIntroLayout.compute(width, height, view, {}, manifest)
  return view
end

local function render(scope, renderer, view)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  renderer:draw(view)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function quantize(value)
  return math.floor(value * 255 + 0.5)
end

function T.card_interiors_preserve_background_while_frames_and_portraits_remain_visible(scope)
  for _, entry in ipairs(readyManifests()) do
    local view = selectorView(entry.manifest, 256, 192)
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local actual = render(scope, renderer, view)
    local backgroundView = selectorView(entry.manifest, 256, 192)
    backgroundView.phase = "background"
    backgroundView.layout = OakIntroLayout.compute(256, 192, backgroundView, {}, entry.manifest)
    local background = render(scope, renderer, backgroundView)
    for gender = 0, 1 do
      local cardEntry = view.layout.genderButtons[gender]
      local card, portrait = cardEntry.rect, cardEntry.portraitRect
      for y = math.floor(card.y + 4), math.ceil(card.y + card.height - 4) - 1 do
        for x = math.floor(card.x + 4), math.ceil(card.x + card.width - 4) - 1 do
          if
            x < portrait.x
            or x >= portrait.x + portrait.width
            or y < portrait.y
            or y >= portrait.y + portrait.height
          then
            local br, bg, bb = background:getPixel(x, y)
            local ar, ag, ab = actual:getPixel(x, y)
            Assert.equal(quantize(ar), quantize(br), entry.versionId .. " card interior red channel")
            Assert.equal(quantize(ag), quantize(bg), entry.versionId .. " card interior green channel")
            Assert.equal(quantize(ab), quantize(bb), entry.versionId .. " card interior blue channel")
          end
        end
      end
    end
    local left = view.layout.genderButtons[0].rect
    local right = view.layout.genderButtons[1].rect
    local x, y = math.floor((left.x + left.width + right.x) / 2), math.floor(left.y + left.height / 2)
    local br, bg, bb, ba = background:getPixel(x, y)
    local ar, ag, ab, aa = actual:getPixel(x, y)
    Assert.equal(quantize(ar), quantize(br))
    Assert.equal(quantize(ag), quantize(bg))
    Assert.equal(quantize(ab), quantize(bb))
    Assert.equal(quantize(aa), quantize(ba))
  end
end

function T.selected_frame_changes_without_recoloring_portraits(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local focusedView = selectorView(entry.manifest, 256, 192, 0, 0)
    local unfocusedView = selectorView(entry.manifest, 256, 192, 1, 0)
    local focused = render(scope, renderer, focusedView)
    local unfocused = render(scope, renderer, unfocusedView)
    local card = focusedView.layout.genderButtons[0].rect
    local changed = false
    for y = math.floor(card.y), math.ceil(card.y + card.height) - 1 do
      for x = math.floor(card.x), math.ceil(card.x + card.width) - 1 do
        local fr, fg, fb = focused:getPixel(x, y)
        local ur, ug, ub = unfocused:getPixel(x, y)
        if quantize(fr) ~= quantize(ur) or quantize(fg) ~= quantize(ug) or quantize(fb) ~= quantize(ub) then
          changed = true
          break
        end
      end
      if changed then
        break
      end
    end
    Assert.isTrue(changed, "focused card rim must differ from its unfocused rendering")
    for gender = 0, 1 do
      local portrait = focusedView.layout.genderButtons[gender].portraitRect
      for y = math.floor(portrait.y), math.ceil(portrait.y + portrait.height) - 1 do
        for x = math.floor(portrait.x), math.ceil(portrait.x + portrait.width) - 1 do
          local fr, fg, fb = focused:getPixel(x, y)
          local ur, ug, ub = unfocused:getPixel(x, y)
          Assert.equal(quantize(fr), quantize(ur), "focus must not recolor portrait red channel")
          Assert.equal(quantize(fg), quantize(ug), "focus must not recolor portrait green channel")
          Assert.equal(quantize(fb), quantize(ub), "focus must not recolor portrait blue channel")
        end
      end
    end
  end
end

function T.both_source_gender_portraits_remain_visible_inside_cards(scope)
  for _, entry in ipairs(readyManifests()) do
    local view = selectorView(entry.manifest, 256, 192)
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local actual = render(scope, renderer, view)
    local backgroundView = selectorView(entry.manifest, 256, 192)
    backgroundView.phase = "background"
    backgroundView.layout = OakIntroLayout.compute(256, 192, backgroundView, {}, entry.manifest)
    local background = render(scope, renderer, backgroundView)
    for gender = 0, 1 do
      local entryLayout = view.layout.genderButtons[gender]
      local portrait = entryLayout.portraitRect
      local card = entryLayout.rect
      Assert.isTrue(portrait.x >= card.x and portrait.y >= card.y)
      Assert.isTrue(portrait.x + portrait.width <= card.x + card.width)
      Assert.isTrue(portrait.y + portrait.height <= card.y + card.height)
      local visible = false
      for y = math.floor(portrait.y), math.ceil(portrait.y + portrait.height) - 1 do
        for x = math.floor(portrait.x), math.ceil(portrait.x + portrait.width) - 1 do
          local actualRed, actualGreen, actualBlue = actual:getPixel(x, y)
          local backgroundRed, backgroundGreen, backgroundBlue = background:getPixel(x, y)
          if
            quantize(actualRed) ~= quantize(backgroundRed)
            or quantize(actualGreen) ~= quantize(backgroundGreen)
            or quantize(actualBlue) ~= quantize(backgroundBlue)
          then
            visible = true
            break
          end
        end
        if visible then
          break
        end
      end
      Assert.isTrue(visible, entry.versionId .. " portrait is not visible")
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "derived_cache" }
return suite
