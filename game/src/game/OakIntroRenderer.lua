-- Responsive Oak/profile renderer. It owns images and atlas crops for the
-- intro manifest; semantic timing and transition decisions remain in the
-- engine controller.

---@class OakIntroRenderer
---@field graphics table
---@field text FieldTextRenderer
local OakIntroRenderer = {}
OakIntroRenderer.__index = OakIntroRenderer
local REQUIRED_ASSETS = { "oak", "marill", "male", "female", "shrink_male", "shrink_female", "ball_open" }

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

local function loadResources(manifest, graphics, imageLoader)
  local images, quads, acquired = {}, {}, {}
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
          width = manifest.background.width,
          height = manifest.background.height,
          duration = 1,
        },
      },
    }
    for assetId, asset in pairs(assets) do
      local image = imageLoader(asset.image)
      assert(image ~= nil, "intro image loader returned no image for " .. assetId)
      acquired[#acquired + 1] = image
      if image.setFilter then
        assert(asset.sampling == "linear" or asset.sampling == "nearest", "intro asset sampling is invalid")
        image:setFilter(asset.sampling, asset.sampling)
      end
      images[assetId] = image
      quads[assetId] = {}
      for frameIndex, frame in ipairs(asset.frames) do
        quads[assetId][frameIndex] =
          graphics.newQuad(frame.x or 0, frame.y or 0, frame.width, frame.height, image:getWidth(), image:getHeight())
      end
    end
  end)
  if not ok then
    releaseAll(acquired)
    error(failure, 0)
  end
  return images, quads, assets
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
  local images, quads, renderedAssets = loadResources(options.manifest, graphics, imageLoader)
  return setmetatable({
    assets = renderedAssets,
    graphics = graphics,
    text = text,
    images = images,
    quads = quads,
    released = false,
  }, OakIntroRenderer)
end

local function drawAsset(self, assetId, frameIndex, region)
  local asset = self.assets[assetId]
  local image = self.images[assetId]
  local quad = self.quads[assetId] and self.quads[assetId][frameIndex or 1]
  assert(asset ~= nil, "intro asset is missing: " .. assetId)
  assert(image ~= nil, "intro image is missing: " .. assetId)
  assert(quad ~= nil, "intro frame is missing: " .. assetId)
  local frame = asset.frames[frameIndex or 1]
  local scale = math.min(region.width / frame.width, region.height / frame.height)
  local x = region.x + (region.width - frame.width * scale) / 2
  local y = region.y + (region.height - frame.height * scale) / 2
  self.graphics.setColor(1, 1, 1, 1)
  self.graphics.draw(image, quad, x, y, 0, scale, scale)
end

local function drawBackground(self, region)
  local asset = assert(self.assets.background, "intro asset is missing: background")
  local image = assert(self.images.background, "intro image is missing: background")
  local quad = assert(self.quads.background and self.quads.background[1], "intro frame is missing: background")
  local frame = asset.frames[1]
  local sx = region.width / frame.width
  local sy = region.height / frame.height
  self.graphics.setColor(1, 1, 1, 1)
  self.graphics.draw(image, quad, region.x, region.y, 0, sx, sy)
end

---@param view table
function OakIntroRenderer:draw(view)
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
  if view.overlayWidget ~= nil then
    drawAsset(self, view.overlayWidget, view.overlayFrameIndex, layout.overlay)
  end
  if view.revealWidget ~= nil and layout.reveal ~= nil then
    drawAsset(self, view.revealWidget, view.revealFrameIndex, layout.reveal)
  end
  if view.flashAlpha > 0 then
    graphics.setColor(1, 1, 1, view.flashAlpha)
    graphics.rectangle("fill", layout.viewport.x, layout.viewport.y, layout.viewport.width, layout.viewport.height)
  end
  if view.phase == "gender_select" or view.phase == "gender_confirm" then
    drawAsset(self, "male", 1, layout.profileCards[0] or layout.cards[0])
    drawAsset(self, "female", 1, layout.profileCards[1] or layout.cards[1])
    graphics.setColor(0.8, 0.9, 1, 1)
    local card = layout.cards[view.genderFocus]
    graphics.rectangle("line", card.x, card.y, card.width, card.height)
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
  self.quads = {}
end

return OakIntroRenderer
