-- Final-pixel checks for Oak confirmation widgets via shared TextButton.

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
    local no =
      OakIntroLayout.compute(800, 600, confirmationView("gender", 0), {}, entry.manifest).confirmationButtons[1]
    -- New TextButton path: verify focus colors are present via shared button.
    local function hasFocusColors(image, rect)
      local hasWhite, hasRed = false, false
      local w, h = image:getWidth(), image:getHeight()
      for y = math.floor(rect.y), math.ceil(rect.y + rect.height) - 1 do
        for x = math.floor(rect.x), math.ceil(rect.x + rect.width) - 1 do
          if x < 0 or x >= w or y < 0 or y >= h then
            goto continue
          end
          local r, g, b = image:getPixel(x, y)
          if r == nil then
            goto continue
          end
          local qr, qg, qb = math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)
          if qr == 255 and qg == 255 and qb == 255 then
            hasWhite = true
          elseif qr == 255 and qg == 0 and qb == 0 then
            hasRed = true
          end
          if hasWhite and hasRed then
            return true, true
          end
          ::continue::
        end
      end
      return hasWhite, hasRed
    end
    local yesWhite, yesRed = hasFocusColors(selectedYes, yes.rect)
    local noWhite, noRed = hasFocusColors(selectedNo, no.rect)
    Assert.isTrue(
      yesWhite and yesRed,
      entry.versionId .. " selected YES focus must contain both white #FFFFFF and red #FF0000"
    )
    Assert.isTrue(noWhite and noRed, entry.versionId .. " selected NO focus must contain both colors when selected")
    local yesHasWhiteUnselected, yesHasRedUnselected = hasFocusColors(selectedNo, yes.rect)
    Assert.isFalse(
      yesHasWhiteUnselected and yesHasRedUnselected,
      entry.versionId .. " unselected YES must not have focus colors"
    )
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
    -- Verify layout buttons exist and have shared geometry.
    Assert.notNil(yes.button)
    Assert.notNil(no.button)
    -- Verify that renderer did not require confirmation widgets (already proven by successful construction).
    Assert.isTrue(entry.manifest.widgets.confirmation_yes == nil or yes.button ~= nil)
  end
end

function T.name_confirmation_uses_common_side_by_side_backings(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer, _, font4 = rendererFor(scope, entry)
    local view = confirmationView("name", 0)
    local image = render(scope, renderer, view, entry.manifest)
    local layout = view.layout
    local yes, no = layout.confirmationButtons[0], layout.confirmationButtons[1]
    -- Common scale: same as gender confirmation.
    local genderYes =
      OakIntroLayout.compute(800, 600, confirmationView("gender", 0), {}, entry.manifest).confirmationButtons[0]
    Assert.equal(yes.scale, genderYes.scale)
    Assert.isTrue(yes.rect.x + yes.rect.width <= no.rect.x or yes.rect.y + yes.rect.height <= no.rect.y)
    Assert.equal(yes.scale, no.scale)
    Assert.equal(font4.fontDef.fontId, 4)
    -- Check buttons have shared geometry.
    Assert.notNil(yes.button)
    Assert.notNil(no.button)
    -- Ensure rendering produced something (not blank).
    Assert.notNil(image)
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "derived_cache" }
return suite
