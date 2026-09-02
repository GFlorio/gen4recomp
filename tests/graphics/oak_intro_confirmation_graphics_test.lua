-- Final-pixel checks for source-backed Oak confirmation widgets and font 4.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local IntroAssetCache = require("libs.assets.src.IntroAssetCache")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

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

local function rendererFor(scope, entry)
  local font0 = scope:own(FieldTextRenderer.new({ cacheFs = entry.cache }))
  local font4 = scope:own(FieldTextRenderer.new({ cacheFs = entry.cache, fontId = 4 }))
  local renderer = OakIntroRenderer.new({
    manifest = entry.manifest,
    text = font0,
    choiceText = font4,
    imageLoader = function(path)
      local bytes = assert(entry.cache:read(path), "missing generated intro image " .. path)
      local image =
        love.graphics.newImage(love.filesystem.newFileData(bytes, path), { linear = false, mipmaps = false })
      image:setFilter("nearest", "nearest")
      return image
    end,
  })
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  return renderer, font0, font4
end

local function confirmationView(kind, selected)
  local phase = kind == "gender" and "gender_confirm" or "name_confirm"
  return {
    phase = phase,
    visual = "background",
    primaryWidget = nil,
    visualFrameIndex = 1,
    sceneBrightness = 0,
    finalFadeAlpha = 0,
    revealBrightness = 0,
    revealOpacity = 1,
    genderFocus = 0,
    genderCompositionProgress = 1,
    confirmationChoice = { kind = kind, selected = selected },
    choiceLabels = { [0] = "YES", [1] = "NO" },
  }
end

local function render(scope, renderer, view, manifest)
  view.layout = OakIntroLayout.compute(800, 600, view, {}, manifest)
  local canvas = scope:own(love.graphics.newCanvas(800, 600))
  love.graphics.setCanvas(canvas)
  renderer:draw(view)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function color(definition, slot)
  local value = assert(definition.palette[slot])
  local r, g, b = value.r or value[1], value.g or value[2], value.b or value[3]
  if r > 1 or g > 1 or b > 1 then
    r, g, b = r / 255, g / 255, b / 255
  end
  return r, g, b
end

local function equalPixel(first, second, x, y)
  local fr, fg, fb = first:getPixel(x, y)
  local sr, sg, sb = second:getPixel(x, y)
  return math.abs(fr - sr) < 1 / 255 and math.abs(fg - sg) < 1 / 255 and math.abs(fb - sb) < 1 / 255
end

function T.source_backing_window_fill_font4_and_selected_focus_are_visible(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer, font0, font4 = rendererFor(scope, entry)
    Assert.equal(font0.fontDef.fontId, 0)
    Assert.equal(font4.fontDef.fontId, 4)
    local selectedYes = render(scope, renderer, confirmationView("gender", 0), entry.manifest)
    local selectedNo = render(scope, renderer, confirmationView("gender", 1), entry.manifest)
    local yes =
      OakIntroLayout.compute(800, 600, confirmationView("gender", 0), {}, entry.manifest).confirmationButtons[0]
    local content = assert(entry.manifest.widgets.confirmation_yes.contentRect)
    local fillX = math.floor(yes.rect.x + (content.x + 1) * yes.scale)
    local fillY = math.floor(yes.rect.y + (content.y + 1) * yes.scale)
    local actualR, actualG, actualB = selectedYes:getPixel(fillX, fillY)
    local expectedR, expectedG, expectedB = color(font4.fontDef, 1)
    Assert.near(actualR, expectedR, 1 / 255, "confirmation window must use font palette slot 0")
    Assert.near(actualG, expectedG, 1 / 255)
    Assert.near(actualB, expectedB, 1 / 255)

    local focusChanged = false
    for y = math.floor(yes.rect.y), math.ceil(yes.rect.y + yes.rect.height) - 1 do
      for x = math.floor(yes.rect.x), math.ceil(yes.rect.x + yes.rect.width) - 1 do
        if not equalPixel(selectedYes, selectedNo, x, y) then
          focusChanged = true
          break
        end
      end
      if focusChanged then
        break
      end
    end
    Assert.isTrue(focusChanged, entry.versionId .. " selected confirmation focus must move between choices")
  end
end

function T.name_confirmation_uses_common_side_by_side_backings(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer, _, font4 = rendererFor(scope, entry)
    local view = confirmationView("name", 0)
    local image = render(scope, renderer, view, entry.manifest)
    local layout = view.layout
    local yes, no = layout.confirmationButtons[0], layout.confirmationButtons[1]
    Assert.isTrue(yes.rect.x + yes.rect.width <= no.rect.x)
    Assert.equal(yes.scale, no.scale)
    Assert.equal(font4.fontDef.fontId, 4)
    local content = assert(entry.manifest.widgets.confirmation_yes.contentRect)
    local backingX = math.floor(yes.rect.x + 2 * yes.scale)
    local backingY = math.floor(yes.rect.y + 2 * yes.scale)
    local contentX = math.floor(yes.rect.x + (content.x + 1) * yes.scale)
    local contentY = math.floor(yes.rect.y + (content.y + 1) * yes.scale)
    local backingR, backingG, backingB = image:getPixel(backingX, backingY)
    local contentR, contentG, contentB = image:getPixel(contentX, contentY)
    Assert.isTrue(
      math.abs(backingR - contentR) > 1 / 255
        or math.abs(backingG - contentG) > 1 / 255
        or math.abs(backingB - contentB) > 1 / 255,
      entry.versionId .. " confirmation backing must remain visible outside its content window"
    )
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "derived_cache" }
return suite
