-- FieldViewport computes pure presentation rectangles for canonical 4:3 field
-- rendering. Expanded mode preserves height and reveals more world horizontally;
-- strict mode centers a 4:3 view, and narrow hosts fall back to strict fitting.

local FieldViewport = {}
FieldViewport.__index = FieldViewport

local function copyRectangle(rectangle)
  return {
    x = rectangle.x,
    y = rectangle.y,
    width = rectangle.width,
    height = rectangle.height,
  }
end

local function strictRectangle(x, y, width, height, aspect)
  if width / height >= aspect then
    local fittedWidth = height * aspect
    return { x = x + (width - fittedWidth) / 2, y = y, width = fittedWidth, height = height }
  end
  local fittedHeight = width / aspect
  return { x = x, y = y + (height - fittedHeight) / 2, width = width, height = fittedHeight }
end

function FieldViewport.new(width, height, options)
  options = options or {}
  local viewport = setmetatable({
    mode = options.mode or "expanded",
    canonicalAspect = options.canonicalAspect or (4 / 3),
    x = options.x or 0,
    y = options.y or 0,
  }, FieldViewport)
  assert(viewport.mode == "expanded" or viewport.mode == "strict", "unsupported field viewport mode")
  assert(viewport.canonicalAspect > 0, "canonical aspect must be positive")
  viewport:resize(width, height)
  return viewport
end

function FieldViewport:resize(width, height)
  assert(type(width) == "number" and width > 0, "viewport width must be positive")
  assert(type(height) == "number" and height > 0, "viewport height must be positive")
  self.width = width
  self.height = height
  local strict = strictRectangle(self.x, self.y, width, height, self.canonicalAspect)
  if self.mode == "strict" or width / height < self.canonicalAspect then
    self.worldViewport = strict
    self.referenceFrame = copyRectangle(strict)
    return
  end
  self.worldViewport = { x = self.x, y = self.y, width = width, height = height }
  self.referenceFrame = {
    x = self.x + (width - height * self.canonicalAspect) / 2,
    y = self.y,
    width = height * self.canonicalAspect,
    height = height,
  }
end

function FieldViewport:worldAspect()
  return self.worldViewport.width / self.worldViewport.height
end

-- The one field-pixel scale calculation shared by the renderer (edge
-- radius) and the field-attached UI: one canonical 256x192 field pixel
-- occupies (referenceFrame.height / 192) host pixels at zoom 1, scaled
-- linearly by the effective camera zoom. The result is the exact non-rounded
-- product -- callers round only when they need an integer quantity (the edge
-- renderer, for example, rounds to its integer neighbor distance). The
-- reference frame is the 4:3 logical field surface (in expanded mode the
-- centered height-spanning rectangle; in strict/fitted mode the fitted 4:3
-- rectangle), so the scale follows the fitted height, not the raw host
-- height.
---@param effectiveZoom number
---@return number
function FieldViewport:logicalPixelScale(effectiveZoom)
  assert(
    type(effectiveZoom) == "number"
      and effectiveZoom > 0
      and effectiveZoom == effectiveZoom
      and effectiveZoom ~= math.huge
      and effectiveZoom ~= -math.huge,
    "effective zoom must be finite and > 0, got " .. tostring(effectiveZoom)
  )
  return (self.referenceFrame.height / 192) * effectiveZoom
end

return FieldViewport
