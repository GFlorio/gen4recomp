-- Responsive Oak/profile renderer. It owns only the images acquired for the
-- intro manifest and consumes controller/layout facts; transition decisions
-- remain in OakIntroController.

---@class OakIntroRenderer
local OakIntroRenderer = {}
OakIntroRenderer.__index = OakIntroRenderer

local function defaultImageLoader(path)
  return love.graphics.newImage(path, { linear = false, mipmaps = false })
end

local function loadImages(manifest, imageLoader)
  local images = {}
  local ok, failure = pcall(function()
    for assetId, asset in pairs(manifest.assets or {}) do
      local image = imageLoader(asset.image)
      assert(image ~= nil, "intro image loader returned no image for " .. assetId)
      if image.setFilter then
        image:setFilter("nearest", "nearest")
      end
      images[assetId] = image
    end
  end)
  if not ok then
    for _, image in pairs(images) do
      if image.release then
        pcall(image.release, image)
      end
    end
    error(failure, 0)
  end
  return images
end

---@param options table
---@return OakIntroRenderer
function OakIntroRenderer.new(options)
  assert(type(options) == "table", "Oak renderer requires options")
  assert(type(options.manifest) == "table", "Oak renderer requires the generated intro manifest")
  local imageLoader = options.imageLoader or defaultImageLoader
  assert(type(imageLoader) == "function", "Oak renderer image loader must be callable")
  return setmetatable({
    manifest = options.manifest,
    images = loadImages(options.manifest, imageLoader),
    released = false,
  }, OakIntroRenderer)
end

local function drawAsset(self, assetId, x, y, width, height)
  local asset = self.manifest.assets[assetId]
  local image = self.images[assetId]
  if asset == nil or image == nil then
    return
  end
  local frame = asset.frames[1]
  local scaleX = width / frame.width
  local scaleY = height / frame.height
  love.graphics.draw(image, x, y, 0, scaleX, scaleY, frame.x, frame.y)
end

---@param view table
function OakIntroRenderer:draw(view)
  assert(not self.released, "Oak renderer is released")
  local layout = view.layout
  love.graphics.setColor(0.04, 0.05, 0.09, 1)
  love.graphics.clear(0.04, 0.05, 0.09, 1)
  local visual = view.visual
  local visualAsset = visual == "background" and "background" or visual
  local viewport = layout.viewport
  drawAsset(self, visualAsset, viewport.x, viewport.y, viewport.width, viewport.height)

  if view.phase == "gender_select" or view.phase == "gender_confirm" then
    drawAsset(self, "gender.male", layout.cards[0].x, layout.cards[0].y, layout.cards[0].width, layout.cards[0].height)
    drawAsset(
      self,
      "gender.female",
      layout.cards[1].x,
      layout.cards[1].y,
      layout.cards[1].width,
      layout.cards[1].height
    )
    love.graphics.setColor(0.8, 0.9, 1, 1)
    love.graphics.rectangle(
      "line",
      layout.cards[view.genderFocus].x,
      layout.cards[view.genderFocus].y,
      layout.cards[view.genderFocus].width,
      layout.cards[view.genderFocus].height
    )
  end

  love.graphics.setColor(1, 1, 1, 1)
  if view.name ~= "" then
    love.graphics.print(view.name, layout.message.x, layout.message.y - 24)
  end
  if view.message ~= nil then
    love.graphics.printf(tostring(view.message), layout.message.x, layout.message.y, layout.message.width, "left")
  end
  if view.phase == "name_edit" then
    for _, entry in ipairs(layout.nameGrid) do
      local label = entry.kind == "glyph" and assert(entry.glyph)
        or entry.kind == "delete" and "Delete"
        or entry.kind == "confirm" and "Confirm"
      assert(label, "Oak layout contains an unknown virtual-key kind")
      love.graphics.printf(label, entry.rect.x, entry.rect.y + 6, entry.rect.width, "center")
    end
  end
end

function OakIntroRenderer:dispose()
  if self.released then
    return
  end
  self.released = true
  for _, image in pairs(self.images) do
    if image.release then
      image:release()
    end
  end
  self.images = {}
end

return OakIntroRenderer
