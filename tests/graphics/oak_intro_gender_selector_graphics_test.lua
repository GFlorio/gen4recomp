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
    local choice = layout.genderChoices[gender - 1]
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

function T.transparent_selector_reveals_the_host_gradient(scope)
  for _, entry in ipairs(readyManifests()) do
    local selector = selectorView(entry.manifest, 256, 192)
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local background = render(scope, renderer, backgroundView(entry.manifest, 256, 192))
    local actual = render(scope, renderer, selector)
    local sourceX, sourceY = 128, 20
    local x = math.floor(selector.layout.genderCanvas.origin.x + sourceX * selector.layout.genderCanvas.scale + 0.5)
    local y = math.floor(selector.layout.genderCanvas.origin.y + sourceY * selector.layout.genderCanvas.scale + 0.5)
    assertSamePixel(background, actual, x, y, entry.versionId .. " transparent selector area")

    local mask = entry.manifest.genderSelector.buttons.male.pulseMask
    local maskData = loadImageData(scope, entry.cache, mask.image)
    local chromeX, chromeY
    for localY = 0, maskData:getHeight() - 1 do
      for localX = 0, maskData:getWidth() - 1 do
        local _, _, _, alpha = maskData:getPixel(localX, localY)
        if alpha > 0 then
          chromeX = mask.bounds.x + localX
          chromeY = mask.bounds.y + localY
          break
        end
      end
      if chromeX ~= nil then
        break
      end
    end
    Assert.notNil(chromeX, entry.versionId .. " generated selector chrome is empty")
    local finalX =
      math.floor(selector.layout.genderCanvas.origin.x + chromeX * selector.layout.genderCanvas.scale + 0.5)
    local finalY =
      math.floor(selector.layout.genderCanvas.origin.y + chromeY * selector.layout.genderCanvas.scale + 0.5)
    local br, bg, bb = background:getPixel(finalX, finalY)
    local ar, ag, ab = actual:getPixel(finalX, finalY)
    Assert.isTrue(
      quantize(ar) ~= quantize(br) or quantize(ag) ~= quantize(bg) or quantize(ab) ~= quantize(bb),
      entry.versionId .. " source-derived selector chrome is not visible"
    )
  end
end

local function selectorViewFor(manifest, width, height, genderFocus, focusBlinkDelta)
  local view = selectorView(manifest, width, height)
  view.genderFocus = genderFocus
  view.focusBlinkDelta = focusBlinkDelta
  view.layout = OakIntroLayout.compute(width, height, view, {}, manifest)
  return view
end

-- Only each card's own pulse/accent role pixels may react to which gender is
-- focused; static backing must stay exactly as transparent (or opaque, for
-- real frame chrome) no matter which card is focused or how far the blink
-- has traveled. A source point clear of both cards is sampled across the two
-- selections and the mid-pulse phase: it must equal the host gradient (never
-- opaque backing) and must not itself change with focus/phase, which would
-- mean it was wrongly wired into a dynamic role instead of being ordinary
-- static backing.
function T.selection_and_pulse_phase_never_reveal_static_backing(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local background = render(scope, renderer, backgroundView(entry.manifest, 256, 192))
    local maleView = selectorViewFor(entry.manifest, 256, 192, 0, 8)
    local femaleView = selectorViewFor(entry.manifest, 256, 192, 1, -8)
    local maleFocused = render(scope, renderer, maleView)
    local femaleFocused = render(scope, renderer, femaleView)

    local canvas = assert(maleView.layout.genderCanvas)
    local sourceX, sourceY = 0, 100
    local x = math.floor(canvas.origin.x + sourceX * canvas.scale + 0.5)
    local y = math.floor(canvas.origin.y + sourceY * canvas.scale + 0.5)

    assertSamePixel(background, maleFocused, x, y, entry.versionId .. " static backing while male is focused")
    assertSamePixel(background, femaleFocused, x, y, entry.versionId .. " static backing while female is focused")
    assertSamePixel(maleFocused, femaleFocused, x, y, entry.versionId .. " static backing must not react to focus")
  end
end

-- Broad DS backing behind/outside/between the two cards must never survive
-- into the final composited frame: at a source point clear of both button
-- frames, the selector draw must let the host background gradient show
-- through exactly as it does at any other transparent selector point.
function T.broad_selector_backing_does_not_survive_final_composition(scope)
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
        entry.versionId .. " " .. sample.name .. " must reveal the host gradient, not selector backing"
      )
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "derived_cache" }
return suite
