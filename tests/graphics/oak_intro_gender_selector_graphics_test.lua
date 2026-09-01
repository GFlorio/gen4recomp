-- Final-pixel checks for the source-derived gender selector compositor. The
-- production manifest and generated images come from the selected ROM cache.

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

local function loadImageData(scope, cache, path)
  local bytes = assert(cache:read(path), "missing generated image " .. path)
  local fileData = love.filesystem.newFileData(bytes, path)
  return scope:own(love.image.newImageData(fileData))
end

local function rendererFor(scope, cache, manifest)
  local renderer = OakIntroRenderer.new({
    manifest = manifest,
    imageLoader = function(path)
      return newImage(cache, path)
    end,
    text = textRenderer(),
  })
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  return renderer
end

local function renderPortraits(scope, cache, manifest, layout)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  for gender, id in ipairs({ "male", "female" }) do
    local widget = manifest.widgets[id]
    local frame = widget.frames[1]
    local image = scope:own(newImage(cache, frame.image))
    image:setFilter(widget.sampling, widget.sampling)
    local choice = layout.genderChoiceGroup.items[gender - 1].payload.portraitRect
    local scale = math.min(choice.width / frame.width, choice.height / frame.height)
    local x = choice.x + (choice.width - frame.width * scale) / 2
    local y = choice.y + (choice.height - frame.height * scale) / 2
    love.graphics.draw(image, x, y, 0, scale, scale)
  end
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function selectorView(manifest, width, height)
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
    genderFocus = 0,
    genderCompositionProgress = 1,
    focusBlinkDelta = 0,
  }
  view.layout = OakIntroLayout.compute(width, height, view, {}, manifest)
  return view
end

local function backgroundView(manifest, width, height)
  local view = selectorView(manifest, width, height)
  view.phase = "background"
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

local function assertSamePixel(expected, actual, x, y, label)
  local er, eg, eb, ea = expected:getPixel(x, y)
  local ar, ag, ab, aa = actual:getPixel(x, y)
  Assert.isTrue(
    quantize(ar) == quantize(er)
      and quantize(ag) == quantize(eg)
      and quantize(ab) == quantize(eb)
      and quantize(aa) == quantize(ea),
    string.format(
      "%s expected (%d,%d,%d,%d), got (%d,%d,%d,%d)",
      label,
      quantize(er),
      quantize(eg),
      quantize(eb),
      quantize(ea),
      quantize(ar),
      quantize(ag),
      quantize(ab),
      quantize(aa)
    )
  )
end

local selectorViewFor

function T.both_portraits_survive_final_composition(scope)
  for _, entry in ipairs(readyManifests()) do
    local view = selectorView(entry.manifest, 256, 192)
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local actual = render(scope, renderer, view)
    local expected = renderPortraits(scope, entry.cache, entry.manifest, view.layout)
    local found = { false, false }
    for y = 0, expected:getHeight() - 1 do
      for x = 0, expected:getWidth() - 1 do
        local _, _, _, alpha = expected:getPixel(x, y)
        if alpha > 0.999 then
          local gender = x < view.layout.selectorPanel.x + view.layout.selectorPanel.width / 2 and 1 or 2
          found[gender] = true
          assertSamePixel(expected, actual, x, y, entry.versionId .. " portrait at " .. x .. "," .. y)
        end
      end
    end
    Assert.isTrue(found[1], entry.versionId .. " male portrait has no visible pixels")
    Assert.isTrue(found[2], entry.versionId .. " female portrait has no visible pixels")
  end
end

local function portraitIsVisibleAt(data, rect, x, y)
  if x < rect.x or y < rect.y or x >= rect.x + rect.width or y >= rect.y + rect.height then
    return false
  end
  local sourceX = math.floor((x - rect.x) / rect.scale)
  local sourceY = math.floor((y - rect.y) / rect.scale)
  if sourceX < 0 or sourceY < 0 or sourceX >= data:getWidth() or sourceY >= data:getHeight() then
    return false
  end
  local _, _, _, alpha = data:getPixel(sourceX, sourceY)
  return alpha > 0
end

local function findStaticCardPixel(scope, cache, manifest, item)
  local button = item.payload.button
  local pulse = loadImageData(scope, cache, button.pulseMask.image)
  local accent = loadImageData(scope, cache, button.accentMask.image)
  local portrait = manifest.widgets[item.payload.portraitId].frames[1]
  local portraitData = loadImageData(scope, cache, portrait.image)
  for localY = 0, button.backing.height - 1 do
    for localX = 0, button.backing.width - 1 do
      local _, _, _, pulseAlpha = pulse:getPixel(localX, localY)
      local _, _, _, accentAlpha = accent:getPixel(localX, localY)
      if pulseAlpha == 0 and accentAlpha == 0 then
        local x = math.floor(item.payload.buttonRect.x + (localX + 0.5) * item.payload.buttonRect.scale + 0.5)
        local y = math.floor(item.payload.buttonRect.y + (localY + 0.5) * item.payload.buttonRect.scale + 0.5)
        if not portraitIsVisibleAt(portraitData, item.payload.portraitRect, x, y) then
          return x, y, localX, localY
        end
      end
    end
  end
  return nil
end

local function findFocusPixel(scope, cache, manifest, item)
  local pulse = loadImageData(scope, cache, item.payload.button.pulseMask.image)
  local portrait = manifest.widgets[item.payload.portraitId].frames[1]
  local portraitData = loadImageData(scope, cache, portrait.image)
  for localY = 0, pulse:getHeight() - 1 do
    for localX = 0, pulse:getWidth() - 1 do
      local _, _, _, alpha = pulse:getPixel(localX, localY)
      if alpha > 0 then
        local x = math.floor(item.payload.buttonRect.x + (localX + 0.5) * item.payload.buttonRect.scale + 0.5)
        local y = math.floor(item.payload.buttonRect.y + (localY + 0.5) * item.payload.buttonRect.scale + 0.5)
        if not portraitIsVisibleAt(portraitData, item.payload.portraitRect, x, y) then
          return x, y
        end
      end
    end
  end
  return nil
end

function T.card_interiors_use_source_backing_and_focus_surfaces(scope)
  for _, entry in ipairs(readyManifests()) do
    local selector = selectorViewFor(entry.manifest, 256, 192, 0, 0)
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local background = render(scope, renderer, backgroundView(entry.manifest, 256, 192))
    local actual = render(scope, renderer, selector)
    for gender = 0, 1 do
      local item = selector.layout.genderChoiceGroup.items[gender]
      local backing = loadImageData(scope, entry.cache, item.payload.button.backing.image)
      local x, y, localX, localY = assert(findStaticCardPixel(scope, entry.cache, entry.manifest, item))
      local expectedR, expectedG, expectedB, expectedA = backing:getPixel(localX, localY)
      local actualR, actualG, actualB, actualA = actual:getPixel(x, y)
      Assert.isTrue(
        quantize(actualR) == quantize(expectedR)
          and quantize(actualG) == quantize(expectedG)
          and quantize(actualB) == quantize(expectedB)
          and quantize(actualA) == quantize(expectedA),
        string.format(
          "%s %s source backing expected (%d,%d,%d,%d), got (%d,%d,%d,%d)",
          entry.versionId,
          item.key,
          quantize(expectedR),
          quantize(expectedG),
          quantize(expectedB),
          quantize(expectedA),
          quantize(actualR),
          quantize(actualG),
          quantize(actualB),
          quantize(actualA)
        )
      )
      local br, bg, bb = background:getPixel(x, y)
      local ar, ag, ab = actual:getPixel(x, y)
      Assert.isTrue(
        quantize(ar) ~= quantize(br) or quantize(ag) ~= quantize(bg) or quantize(ab) ~= quantize(bb),
        entry.versionId .. " " .. item.key .. " backing must cover the host gradient"
      )
    end
  end
end

selectorViewFor = function(manifest, width, height, genderFocus, focusBlinkDelta)
  local view = selectorView(manifest, width, height)
  view.genderFocus = genderFocus
  view.focusBlinkDelta = focusBlinkDelta
  view.layout = OakIntroLayout.compute(width, height, view, {}, manifest)
  return view
end

function T.selection_changes_each_card_focus_surface(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    for focused = 0, 1 do
      local focusedView = selectorViewFor(entry.manifest, 256, 192, focused, 0)
      local otherView = selectorViewFor(entry.manifest, 256, 192, 1 - focused, 0)
      local focusedImage = render(scope, renderer, focusedView)
      local otherImage = render(scope, renderer, otherView)
      local item = focusedView.layout.genderChoiceGroup.items[focused]
      local x, y = findFocusPixel(scope, entry.cache, entry.manifest, item)
      Assert.notNil(x, entry.versionId .. " " .. item.key .. " has no focus pixel")
      Assert.notNil(y, entry.versionId .. " " .. item.key .. " has no focus pixel")
      x, y = assert(x), assert(y)
      local fr, fg, fb = focusedImage:getPixel(x, y)
      local or_, og, ob = otherImage:getPixel(x, y)
      Assert.isTrue(
        quantize(fr) ~= quantize(or_) or quantize(fg) ~= quantize(og) or quantize(fb) ~= quantize(ob),
        entry.versionId .. " " .. item.key .. " focus surface does not react to selection"
      )
    end
  end
end

function T.host_gradient_remains_outside_and_between_cards(scope)
  for _, entry in ipairs(readyManifests()) do
    local selector = selectorView(entry.manifest, 256, 192)
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local background = render(scope, renderer, backgroundView(entry.manifest, 256, 192))
    local actual = render(scope, renderer, selector)

    local male = entry.manifest.genderSelector.buttons.male.bounds
    local samples = {
      { name = "left margin, level with the cards", x = 0, y = 100 },
      { name = "bottom fill, left of both cards", x = 0, y = 190 },
      { name = "bottom fill, between the cards", x = male.x + male.width + 10, y = 190 },
    }
    for _, sample in ipairs(samples) do
      local x = math.floor(selector.layout.genderCanvas.origin.x + sample.x * selector.layout.genderCanvas.scale + 0.5)
      local y = math.floor(selector.layout.genderCanvas.origin.y + sample.y * selector.layout.genderCanvas.scale + 0.5)
      assertSamePixel(
        background,
        actual,
        x,
        y,
        entry.versionId .. " " .. sample.name .. " must retain the host gradient"
      )
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "derived_cache" }
return suite
