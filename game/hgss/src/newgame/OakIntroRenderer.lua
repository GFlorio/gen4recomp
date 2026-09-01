-- Responsive Oak/profile renderer. It owns images and atlas crops for the
-- intro manifest; semantic timing and transition decisions remain in the
-- engine controller.

---@class OakIntroRenderer
---@field graphics table
---@field text FieldTextRenderer
---@field assets table
---@field bindings table
---@field manifest table
local OakIntroRenderer = {}
OakIntroRenderer.__index = OakIntroRenderer
local ButtonPainter = require("game.hgss.src.ui.ButtonPainter")
local REQUIRED_ASSETS = {
  "oak",
  "marill",
  "marill_appear",
  "male",
  "female",
  "shrink_male",
  "shrink_female",
  "ball_open",
  "gender_male",
  "gender_female",
}

local REVEAL_SHADER = [[
  uniform number brightness;
  vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    vec4 sampled = Texel(texture, texture_coords) * color;
    sampled.rgb = mix(sampled.rgb, vec3(1.0), brightness);
    return sampled;
  }
]]

local PROFILE_CARD = {
  border = { 58, 58, 58 },
  selectedRim = { 255, 58, 58 },
  unselectedRim = { 222, 230, 230 },
  face = { 16, 189, 255 },
}

local CONFIRMATION = {
  border = { 66, 66, 66 },
  rim = { 230, 230, 222 },
  innerBorder = { 25, 189, 197 },
  faceTop = { 49, 222, 230 },
  faceBottom = { 8, 156, 165 },
}

local function clamp(value)
  return math.max(0, math.min(1, value))
end

local function referenceColor(value)
  return { value[1] / 255, value[2] / 255, value[3] / 255 }
end

local function profilePalette(manifest, selected, focusBlinkDelta)
  local tone = assert(manifest.genderSelector and manifest.genderSelector.defaultTone)
  local delta = selected and (focusBlinkDelta or 0) / 31 or 0
  return {
    border = referenceColor(PROFILE_CARD.border),
    rim = referenceColor(selected and PROFILE_CARD.selectedRim or PROFILE_CARD.unselectedRim),
    innerBorder = {
      clamp(tone.r / 255 + delta),
      clamp(tone.g / 255 + delta),
      clamp(tone.b / 255 + delta),
    },
    faceTop = referenceColor(PROFILE_CARD.face),
    faceBottom = referenceColor(PROFILE_CARD.face),
  }
end

local function confirmationPalette()
  return {
    border = referenceColor(CONFIRMATION.border),
    rim = referenceColor(CONFIRMATION.rim),
    innerBorder = referenceColor(CONFIRMATION.innerBorder),
    faceTop = referenceColor(CONFIRMATION.faceTop),
    faceBottom = referenceColor(CONFIRMATION.faceBottom),
  }
end

local function defaultImageLoader(path)
  return love.graphics.newImage(path, { linear = false, mipmaps = false })
end

local function releaseAll(resources)
  for index = #resources, 1, -1 do
    if resources[index].release then
      pcall(resources[index].release, resources[index])
    end
  end
end

-- Generated intro widgets share one image acquisition and release owner.
local function loadResources(manifest, graphics, imageLoader)
  local bindings, acquired = {}, {}
  local imagesByPath = {}
  local assets = {}
  local ok, failure = pcall(function()
    for assetId, asset in pairs(manifest.widgets) do
      assets[assetId] = asset
    end
    assets.background = {
      image = manifest.background.image,
      width = manifest.background.width,
      height = manifest.background.height,
      sampling = manifest.background.sampling,
      frames = {
        {
          x = 0,
          y = 0,
          image = manifest.background.image,
          width = manifest.background.width,
          height = manifest.background.height,
          duration = 1,
        },
      },
    }
    for assetId, asset in pairs(assets) do
      bindings[assetId] = {}
      for frameIndex, frame in ipairs(asset.frames) do
        local image = imagesByPath[frame.image]
        if image == nil then
          image = imageLoader(frame.image)
          assert(image ~= nil, "intro image loader returned no image for " .. assetId)
          imagesByPath[frame.image] = image
          acquired[#acquired + 1] = image
          if image.setFilter then
            assert(asset.sampling == "linear" or asset.sampling == "nearest", "intro asset sampling is invalid")
            image:setFilter(asset.sampling, asset.sampling)
          end
        end
        local quad =
          graphics.newQuad(frame.x or 0, frame.y or 0, frame.width, frame.height, image:getWidth(), image:getHeight())
        bindings[assetId][frameIndex] = { image = image, quad = quad }
      end
    end
  end)
  if not ok then
    releaseAll(acquired)
    error(failure, 0)
  end
  return imagesByPath, bindings, assets
end

---@param options table
---@return OakIntroRenderer
function OakIntroRenderer.new(options)
  assert(type(options) == "table", "Oak renderer requires options")
  assert(type(options.manifest) == "table", "Oak renderer requires the generated intro manifest")
  assert(type(options.manifest.widgets) == "table", "Oak renderer requires generated intro widgets")
  assert(type(options.manifest.background) == "table", "Oak renderer requires a generated intro background")
  local assets = options.manifest.widgets
  assert(options.manifest.background, "Oak renderer requires a generated background")
  for _, assetId in ipairs(REQUIRED_ASSETS) do
    assert(assets[assetId], "Oak renderer requires generated asset " .. assetId)
  end
  local graphics = options.graphics or love.graphics
  local text = assert(options.text, "Oak renderer requires the shared FieldTextRenderer")
  assert(type(text.drawText) == "function", "Oak renderer requires FieldTextRenderer.drawText")
  local imageLoader = options.imageLoader or defaultImageLoader
  assert(type(imageLoader) == "function", "Oak renderer image loader must be callable")
  local images, bindings, renderedAssets = loadResources(options.manifest, graphics, imageLoader)
  local ok, revealShader = pcall(graphics.newShader, REVEAL_SHADER)
  if not ok then
    local acquired = {}
    for _, image in pairs(images) do
      acquired[#acquired + 1] = image
    end
    releaseAll(acquired)
    error(revealShader, 0)
  end
  if revealShader == nil then
    local acquired = {}
    for _, image in pairs(images) do
      acquired[#acquired + 1] = image
    end
    releaseAll(acquired)
    error("Oak renderer shader construction returned no shader", 0)
  end
  return setmetatable({
    assets = renderedAssets,
    manifest = options.manifest,
    graphics = graphics,
    text = text,
    images = images,
    bindings = bindings,
    revealShader = revealShader,
    released = false,
  }, OakIntroRenderer)
end

local function drawAsset(self, assetId, frameIndex, region, opacity, brightness, tint)
  local asset = self.assets[assetId]
  assert(asset ~= nil, "intro asset is missing: " .. assetId)
  local frame = asset.frames[frameIndex or 1]
  local binding = self.bindings[assetId] and self.bindings[assetId][frameIndex or 1]
  assert(binding ~= nil, "intro frame is missing: " .. assetId)
  local isSourcePlaced = region.scale ~= nil
  local scale, x, y
  if isSourcePlaced then
    scale = region.scale
    x = region.x
    y = region.y
  else
    scale = math.min(region.width / frame.width, region.height / frame.height)
    x = region.x + (region.width - frame.width * scale) / 2
    y = region.y + (region.height - frame.height * scale) / 2
  end
  if brightness ~= nil then
    assert(brightness >= 0 and brightness <= 1, "intro reveal brightness is out of range")
  end
  if opacity ~= nil then
    assert(opacity >= 0 and opacity <= 1, "intro reveal opacity is out of range")
  end
  if brightness and brightness > 0 then
    self.revealShader:send("brightness", brightness)
    self.graphics.setShader(self.revealShader)
  end
  local tr, tg, tb = 1, 1, 1
  if tint ~= nil then
    tr, tg, tb = tint.r or tint[1], tint.g or tint[2], tint.b or tint[3]
  end
  self.graphics.setColor(tr, tg, tb, opacity or 1)
  self.graphics.draw(binding.image, binding.quad, x, y, 0, scale, scale)
  if brightness and brightness > 0 then
    self.graphics.setShader(nil)
  end
end

local function drawBackground(self, region)
  local asset = assert(self.assets.background, "intro asset is missing: background")
  local binding = assert(self.bindings.background and self.bindings.background[1], "intro frame is missing: background")
  local frame = asset.frames[1]
  local sx = region.width / frame.width
  local sy = region.height / frame.height
  self.graphics.setColor(1, 1, 1, 1)
  self.graphics.draw(binding.image, binding.quad, region.x, region.y, 0, sx, sy)
end

local function drawSourceScaleText(self, text, textRect, textScale, tint)
  local lineHeight = assert(self.text.fontDef and self.text.fontDef.lineHeight)
  local width = self.text:textWidth(text)
  assert(width > 0 and textScale > 0, "Oak choice text metrics are invalid")
  assert(width * textScale <= textRect.width + 1e-9, "Oak choice text is wider than its source bounds")
  assert(lineHeight * textScale <= textRect.height + 1e-9, "Oak choice text is taller than its source bounds")
  local x = textRect.x + (textRect.width - width * textScale) / 2
  local y = textRect.y + (textRect.height - lineHeight * textScale) / 2
  self.graphics.setColor(tint[1], tint[2], tint[3], tint[4] or 1)
  self.graphics.push()
  self.graphics.translate(x, y)
  self.graphics.scale(textScale, textScale)
  self.text:drawText(text, 0, 0)
  self.graphics.pop()
end

---@param view table
function OakIntroRenderer:_draw(view)
  assert(not self.released, "Oak renderer is released")
  local graphics = self.graphics
  local layout = view.layout
  graphics.clear(0.04, 0.05, 0.09, 1)
  drawBackground(self, layout.viewport)
  if view.primaryWidget ~= nil then
    drawAsset(self, view.primaryWidget, view.visualFrameIndex, layout.subject)
  elseif view.visual ~= "background" then
    drawAsset(self, view.visual, view.visualFrameIndex, layout.subject)
  end
  if view.revealWidget ~= nil and layout.reveal ~= nil then
    drawAsset(self, view.revealWidget, view.revealFrameIndex, layout.reveal, view.revealOpacity, view.revealBrightness)
  end
  if view.sceneBrightness > 0 then
    assert(view.sceneBrightness <= 1, "intro scene brightness is out of range")
    graphics.setColor(1, 1, 1, view.sceneBrightness)
    graphics.rectangle("fill", layout.viewport.x, layout.viewport.y, layout.viewport.width, layout.viewport.height)
  end
  local finalFadeAlpha = view.finalFadeAlpha or 0
  if finalFadeAlpha > 0 then
    graphics.setColor(0, 0, 0, finalFadeAlpha)
    graphics.rectangle("fill", layout.viewport.x, layout.viewport.y, layout.viewport.width, layout.viewport.height)
  end
  if view.phase == "gender_select" or view.phase == "gender_confirm" then
    if view.phase == "gender_select" then
      for gender = 0, 1 do
        local entry = assert(layout.genderButtons and layout.genderButtons[gender])
        local selected = view.genderFocus == gender
        ButtonPainter.draw(
          graphics,
          entry.button,
          profilePalette(self.manifest, selected, selected and view.focusBlinkDelta or 0)
        )
        drawAsset(self, entry.portraitId, 1, entry.portraitRect)
      end
    elseif layout.selectedProfileButton then
      local entry = layout.selectedProfileButton
      ButtonPainter.draw(graphics, entry.button, profilePalette(self.manifest, true, 0))
      drawAsset(self, entry.portraitId, 1, entry.portraitRect)
    end
  end
  if layout.confirmationButtons then
    local labels = assert(view.choiceLabels)
    for choice = 0, 1 do
      local entry = assert(layout.confirmationButtons[choice])
      local selected = view.confirmationChoice.selected == choice
      ButtonPainter.draw(graphics, entry.button, confirmationPalette())
      drawSourceScaleText(
        self,
        assert(labels[choice]),
        entry.textRect,
        entry.textScale,
        selected and { 1, 1, 1, 1 } or { 0.75, 0.75, 0.75, 1 }
      )
    end
  end
  graphics.setColor(1, 1, 1, 1)
  if view.phase == "name_edit" and view.name ~= "" then
    local preview = assert(layout.namePreview, "Oak name preview is missing")
    local textWidth = self.text.textWidth and self.text:textWidth(view.name) or 0
    self.text:drawText(view.name, preview.x + (preview.width - textWidth) / 2, preview.y + (preview.height - 16) / 2)
  end
  if view.phase == "name_edit" then
    for _, entry in ipairs(layout.nameKeys or layout.nameGrid) do
      local width = self.text.textWidth and self.text:textWidth(entry.label) or 0
      self.text:drawText(entry.label, entry.rect.x + (entry.rect.width - width) / 2, entry.rect.y + 6)
    end
    local focused = assert(layout.nameKeys[view.virtualGlyphFocus], "Oak virtual focus is invalid")
    graphics.setColor(0.8, 0.9, 1, 1)
    graphics.rectangle("line", focused.rect.x, focused.rect.y, focused.rect.width, focused.rect.height)
  end
end

function OakIntroRenderer:draw(view)
  assert(not self.released, "Oak renderer is released")
  local graphics = self.graphics
  local red, green, blue, alpha = graphics.getColor()
  local shader = graphics.getShader()
  local ok, failure = xpcall(function()
    self:_draw(view)
  end, debug.traceback)
  graphics.setShader(shader)
  graphics.setColor(red, green, blue, alpha)
  if not ok then
    error(failure, 0)
  end
end

function OakIntroRenderer:dispose()
  if self.released then
    return
  end
  self.released = true
  local resources = {}
  for _, image in pairs(self.images) do
    resources[#resources + 1] = image
  end
  releaseAll(resources)
  self.images = {}
  self.bindings = {}
  if self.revealShader and self.revealShader.release then
    self.revealShader:release()
  end
  self.revealShader = nil
end

return OakIntroRenderer
