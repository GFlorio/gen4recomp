-- Responsive Oak/profile renderer. It owns images and atlas crops for the
-- intro manifest; semantic timing and transition decisions remain in the
-- engine controller.

---@class OakIntroRenderer
---@field graphics table
---@field text FieldTextRenderer
---@field genderSelector table generated selector chrome/pulse/accent/tone semantics
---@field assets table
---@field bindings table
local OakIntroRenderer = {}
OakIntroRenderer.__index = OakIntroRenderer
local ChoiceGroup = require("libs.ui.src.ChoiceGroup")
local PaintList = require("libs.ui.src.PaintList")
local OakChoiceStyles = require("game.hgss.src.newgame.OakChoiceStyles")
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

-- Generated choice surfaces are represented as ordinary single-frame assets so
-- the renderer retains one image acquisition and release owner.
local function choiceAssets(manifest)
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
  for _, gender in ipairs({ "male", "female" }) do
    local button = manifest.genderSelector.buttons[gender]
    for _, kind in ipairs({ "backing", "pulseMask", "accentMask" }) do
      local mask = button[kind]
      single("genderSelector." .. gender .. "." .. kind, mask.image, mask.width, mask.height)
    end
    for _, choice in ipairs({ "yes", "no" }) do
      local confirmation = manifest.profileConfirmation.buttons[gender][choice]
      for _, kind in ipairs({ "base", "focus" }) do
        local surface = confirmation[kind]
        single(
          "profileConfirmation." .. gender .. "." .. choice .. "." .. kind,
          surface.image,
          surface.width,
          surface.height
        )
      end
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
    for assetId, asset in pairs(choiceAssets(manifest)) do
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
    selector.neutral == nil and type(selector.defaultTone) == "table" and type(selector.buttons) == "table",
    "Oak renderer requires v6 gender selector semantics"
  )
  assert(type(options.manifest.profileConfirmation) == "table", "Oak renderer requires profile confirmation semantics")
  for _, gender in ipairs({ "male", "female" }) do
    local button = selector.buttons[gender]
    assert(type(button) == "table", "Oak renderer is missing the gender selector " .. gender .. " button")
    for _, kind in ipairs({ "backing", "pulseMask", "accentMask" }) do
      local mask = button[kind]
      assert(
        type(mask) == "table"
          and type(mask.image) == "string"
          and type(mask.width) == "number"
          and type(mask.height) == "number"
          and mask.width > 0
          and mask.height > 0,
        "Oak renderer is missing the gender selector " .. gender .. " " .. kind
      )
    end
    local confirmation = options.manifest.profileConfirmation.buttons[gender]
    assert(type(confirmation) == "table", "Oak renderer is missing profile confirmation " .. gender)
    for _, choice in ipairs({ "yes", "no" }) do
      for _, kind in ipairs({ "base", "focus" }) do
        local surface = confirmation[choice][kind]
        assert(type(surface) == "table" and type(surface.image) == "string")
      end
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

function OakIntroRenderer:_executePaintList(paintList)
  for _, command in ipairs(paintList:commands()) do
    if command.kind == "image" then
      drawAsset(self, command.assetKey, 1, command.rect, nil, nil, command.tint)
    else
      local destination = command.rect
      local lineHeight = assert(self.text.fontDef and self.text.fontDef.lineHeight)
      local width = self.text:textWidth(command.text)
      self.graphics.push()
      self.graphics.translate(destination.x + destination.width / 2, destination.y + destination.height / 2)
      self.graphics.scale(command.scale, command.scale)
      self.text:drawText(command.text, -width / 2, -lineHeight / 2)
      self.graphics.pop()
    end
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
    local paintList = PaintList.new()
    if view.phase == "gender_select" then
      ChoiceGroup.paint(
        assert(layout.genderChoiceGroup),
        paintList,
        OakChoiceStyles.paintProfileChoice,
        { selector = self.genderSelector, focusBlinkDelta = assert(view.focusBlinkDelta) }
      )
    elseif layout.selectedProfileCard then
      OakChoiceStyles.paintStaticProfileCard(paintList, layout.selectedProfileCard, { selector = self.genderSelector })
    end
    self:_executePaintList(paintList)
  end
  if layout.confirmationChoiceGroup then
    local paintList = PaintList.new()
    ChoiceGroup.paint(layout.confirmationChoiceGroup, paintList, OakChoiceStyles.paintConfirmationChoice, {
      gender = view.genderFocus == 0 and "male" or "female",
      labels = assert(view.choiceLabels),
    })
    self:_executePaintList(paintList)
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
