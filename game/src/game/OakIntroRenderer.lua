-- Responsive Oak/profile renderer. It owns images and atlas crops for the
-- intro manifest; semantic timing and transition decisions remain in the
-- engine controller.

---@class OakIntroRenderer
---@field graphics table
---@field text FieldTextRenderer
---@field genderSelector table generated C01 neutral surface/pulse/accent/tone semantics
local OakIntroRenderer = {}
OakIntroRenderer.__index = OakIntroRenderer
local REQUIRED_ASSETS = {
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
}

local REVEAL_SHADER = [[
  uniform number brightness;
  vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    vec4 sampled = Texel(texture, texture_coords) * color;
    sampled.rgb = mix(sampled.rgb, vec3(1.0), brightness);
    return sampled;
  }
]]

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

-- Gender selector masks/neutral surface are single-frame source-cropped
-- images, same as any other widget asset, addressed under synthetic
-- "genderSelector.<gender>.<kind>" ids so the ordinary widget loader/binder
-- can load and quad them without a second resource-loading path.
local function genderSelectorAssets(selector)
  local assets = {}
  local function single(id, image, width, height)
    assets[id] = {
      image = image,
      width = width,
      height = height,
      sampling = "nearest",
      frames = { { x = 0, y = 0, image = image, width = width, height = height, duration = 1 } },
    }
  end
  single("genderSelector.neutral", selector.neutral.image, selector.neutral.width, selector.neutral.height)
  for _, gender in ipairs({ "male", "female" }) do
    local button = selector.buttons[gender]
    for _, kind in ipairs({ "pulseMask", "accentMask" }) do
      local mask = button[kind]
      single("genderSelector." .. gender .. "." .. kind, mask.image, mask.width, mask.height)
    end
  end
  return assets
end

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
    for assetId, asset in pairs(genderSelectorAssets(manifest.genderSelector)) do
      assets[assetId] = asset
    end
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
  local selector = options.manifest.genderSelector
  assert(type(selector) == "table", "Oak renderer requires the generated gender selector semantics")
  assert(
    type(selector.neutral) == "table" and type(selector.neutral.image) == "string",
    "Oak renderer requires the gender selector neutral surface"
  )
  assert(type(selector.defaultTone) == "table", "Oak renderer requires the gender selector default tone")
  assert(type(selector.buttons) == "table", "Oak renderer requires gender selector buttons")
  for _, gender in ipairs({ "male", "female" }) do
    local button = selector.buttons[gender]
    assert(type(button) == "table", "Oak renderer is missing the gender selector " .. gender .. " button")
    for _, kind in ipairs({ "pulseMask", "accentMask" }) do
      local mask = button[kind]
      assert(
        type(mask) == "table" and type(mask.image) == "string" and type(mask.bounds) == "table",
        "Oak renderer is missing the gender selector " .. gender .. " " .. kind
      )
    end
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
  return setmetatable({
    assets = renderedAssets,
    genderSelector = selector,
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
    tr, tg, tb = tint[1], tint[2], tint[3]
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

-- OakSpeech_BlinkHighlightedGenderFrame (pinned source) sine-modulates the
-- selected button's frame tone and reddens its accent, restoring the
-- unselected frame to the neutral default tone/gray accent. Both channels
-- are RGB555-domain values (0..31) expanded to renderer color space.
local SELECTED_ACCENT = { 31, 7, 7 }
local UNSELECTED_ACCENT = { 27, 28, 28 }

local function expandChannel(value)
  return math.floor((value * 255 + 15) / 31) / 255
end

local function canvasRect(canvas, bounds)
  return {
    x = canvas.origin.x + bounds.x * canvas.scale,
    y = canvas.origin.y + bounds.y * canvas.scale,
    width = bounds.width * canvas.scale,
    height = bounds.height * canvas.scale,
    scale = canvas.scale,
  }
end

---@param view table
---@param layout table
function OakIntroRenderer:_drawGenderFocus(view, layout)
  local canvas = assert(layout.genderCanvas, "Oak layout must expose the gender selector canvas")
  local selector = self.genderSelector
  local delta = view.focusBlinkDelta
  assert(type(delta) == "number", "gender focus requires a blink delta")
  local pulseChannel = math.max(0, math.min(31, 16 + delta))
  local focusedTone = expandChannel(pulseChannel)
  local defaultTone = selector.defaultTone
  local defaultToneTint = { defaultTone.r / 255, defaultTone.g / 255, defaultTone.b / 255 }
  for gender, key in pairs({ [0] = "male", [1] = "female" }) do
    local isFocused = view.genderFocus == gender
    local button = assert(selector.buttons[key])
    local toneTint = isFocused and { focusedTone, focusedTone, focusedTone } or defaultToneTint
    local accent = isFocused and SELECTED_ACCENT or UNSELECTED_ACCENT
    local accentTint = { expandChannel(accent[1]), expandChannel(accent[2]), expandChannel(accent[3]) }
    drawAsset(
      self,
      "genderSelector." .. key .. ".pulseMask",
      1,
      canvasRect(canvas, button.pulseMask.bounds),
      1,
      nil,
      toneTint
    )
    drawAsset(
      self,
      "genderSelector." .. key .. ".accentMask",
      1,
      canvasRect(canvas, button.accentMask.bounds),
      1,
      nil,
      accentTint
    )
  end
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
    drawAsset(self, "gender_background", 1, assert(layout.genderBackground))
    drawAsset(self, "gender_male", 1, assert(layout.genderChoices[0]))
    drawAsset(self, "gender_female", 1, assert(layout.genderChoices[1]))
    self:_drawGenderFocus(view, layout)
  end
  if view.confirmationChoice then
    local rows = assert(layout.choiceRows)
    local labels = assert(view.choiceLabels)
    for selected = 0, 1 do
      local row = rows[selected]
      graphics.setColor(
        selected == view.confirmationChoice.selected and 0.18 or 0.08,
        selected == view.confirmationChoice.selected and 0.35 or 0.12,
        selected == view.confirmationChoice.selected and 0.62 or 0.2,
        1
      )
      graphics.rectangle("fill", row.x, row.y, row.width, row.height)
      graphics.setColor(1, 1, 1, 1)
      local label = labels[selected]
      local width = self.text.textWidth and self.text:textWidth(label) or 0
      self.text:drawText(label, row.x + (row.width - width) / 2, row.y + (row.height - 16) / 2)
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
