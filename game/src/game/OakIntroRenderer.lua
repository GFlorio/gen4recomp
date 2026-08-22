-- Responsive Oak/profile renderer. It owns images and atlas crops for the
-- intro manifest; semantic timing and transition decisions remain in the
-- engine controller.

---@class OakIntroRenderer
---@field graphics table
local OakIntroRenderer = {}
OakIntroRenderer.__index = OakIntroRenderer

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
  local ok, failure = pcall(function()
    for assetId, asset in pairs(manifest.assets) do
      local image = imageLoader(asset.image)
      assert(image ~= nil, "intro image loader returned no image for " .. assetId)
      acquired[#acquired + 1] = image
      if image.setFilter then
        image:setFilter("nearest", "nearest")
      end
      images[assetId] = image
      quads[assetId] = {}
      for frameIndex, frame in ipairs(asset.frames) do
        quads[assetId][frameIndex] =
          graphics.newQuad(frame.x, frame.y, frame.width, frame.height, image:getWidth(), image:getHeight())
      end
    end
  end)
  if not ok then
    releaseAll(acquired)
    error(failure, 0)
  end
  return images, quads
end

---@param options table
---@return OakIntroRenderer
function OakIntroRenderer.new(options)
  assert(type(options) == "table", "Oak renderer requires options")
  assert(
    type(options.manifest) == "table" and type(options.manifest.assets) == "table",
    "Oak renderer requires the generated intro manifest"
  )
  local graphics = options.graphics or love.graphics
  local imageLoader = options.imageLoader or defaultImageLoader
  assert(type(imageLoader) == "function", "Oak renderer image loader must be callable")
  local images, quads = loadResources(options.manifest, graphics, imageLoader)
  return setmetatable(
    { manifest = options.manifest, graphics = graphics, images = images, quads = quads, released = false },
    OakIntroRenderer
  )
end

local function messageText(message)
  if type(message) == "string" then
    return message
  end
  if type(message) == "table" then
    if type(message.text) == "string" then
      return message.text
    end
    if type(message.payload) == "string" then
      return message.payload
    end
  end
  return tostring(message)
end

local function drawAsset(self, assetId, frameIndex, region, offsetX)
  local asset = self.manifest.assets[assetId]
  local image = self.images[assetId]
  local quad = self.quads[assetId] and self.quads[assetId][frameIndex or 1]
  assert(asset ~= nil, "intro asset is missing: " .. assetId)
  assert(image ~= nil, "intro image is missing: " .. assetId)
  assert(quad ~= nil, "intro frame is missing: " .. assetId)
  local frame = asset.frames[frameIndex or 1]
  local scale = math.min(region.width / frame.width, region.height / frame.height)
  local x = region.x + (region.width - frame.width * scale) / 2 + (offsetX or 0)
  local y = region.y + (region.height - frame.height * scale) / 2
  self.graphics.draw(image, quad, x, y, 0, scale, scale)
end

---@param view table
function OakIntroRenderer:draw(view)
  assert(not self.released, "Oak renderer is released")
  local graphics = self.graphics
  local layout = view.layout
  graphics.setColor(0.04, 0.05, 0.09, 1)
  graphics.clear(0.04, 0.05, 0.09, 1)
  drawAsset(self, "background", 1, layout.viewport)
  if view.visual ~= "background" then
    drawAsset(self, view.visual, view.visualFrameIndex, layout.subject, view.oakOffsetX)
  end
  if view.flashAlpha > 0 then
    graphics.setColor(1, 1, 1, view.flashAlpha)
    graphics.rectangle("fill", layout.viewport.x, layout.viewport.y, layout.viewport.width, layout.viewport.height)
  end
  if view.phase == "gender_select" or view.phase == "gender_confirm" then
    drawAsset(self, "gender.male", 1, layout.cards[0])
    drawAsset(self, "gender.female", 1, layout.cards[1])
    graphics.setColor(0.8, 0.9, 1, 1)
    local card = layout.cards[view.genderFocus]
    graphics.rectangle("line", card.x, card.y, card.width, card.height)
  end
  graphics.setColor(1, 1, 1, 1)
  if view.name ~= "" then
    graphics.print(view.name, layout.message.x, layout.message.y - 24)
  end
  if view.message ~= nil then
    graphics.printf(messageText(view.message), layout.message.x, layout.message.y, layout.message.width, "left")
  end
  if view.phase == "name_edit" then
    for _, entry in ipairs(layout.nameGrid) do
      local label = entry.kind == "glyph" and assert(entry.glyph)
        or entry.kind == "delete" and "Delete"
        or entry.kind == "confirm" and "Confirm"
      assert(label, "Oak layout contains an unknown virtual-key kind")
      graphics.printf(label, entry.rect.x, entry.rect.y + 6, entry.rect.width, "center")
    end
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
