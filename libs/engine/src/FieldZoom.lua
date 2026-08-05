-- FieldZoom owns manual field-camera zoom and the configurable response to host
-- height changes. It is pure presentation state and never alters simulation or
-- ROM-derived camera geometry.

local FieldZoom = {}
FieldZoom.__index = FieldZoom

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

function FieldZoom.new(config)
  config = config or {}
  local minimum = config.minZoom or 0.5
  local maximum = config.maxZoom or 1.5
  local initial = config.manualZoom or 1
  local referenceHeight = config.referenceHeight or 720
  local compensation = config.resizeCompensation or 0
  local step = config.step or 0.1
  assert(type(minimum) == "number" and minimum > 0, "minimum zoom must be positive")
  assert(type(maximum) == "number" and maximum >= minimum, "maximum zoom must not be below minimum")
  assert(type(initial) == "number" and initial >= minimum and initial <= maximum,
    "manual zoom must be within bounds")
  assert(type(referenceHeight) == "number" and referenceHeight > 0, "reference height must be positive")
  assert(type(compensation) == "number" and compensation >= 0 and compensation <= 1,
    "resize compensation must be between zero and one")
  assert(type(step) == "number" and step > 0, "zoom step must be positive")
  return setmetatable({
    minZoom = minimum,
    maxZoom = maximum,
    defaultManualZoom = initial,
    manualZoom = initial,
    referenceHeight = referenceHeight,
    resizeCompensation = compensation,
    step = step,
    viewportHeight = referenceHeight,
  }, FieldZoom)
end

function FieldZoom:resize(viewportHeight)
  assert(type(viewportHeight) == "number" and viewportHeight > 0,
    "zoom viewport height must be positive")
  self.viewportHeight = viewportHeight
end

function FieldZoom:effectiveZoom()
  local resizeZoom = (self.referenceHeight / self.viewportHeight) ^ self.resizeCompensation
  return clamp(self.manualZoom * resizeZoom, self.minZoom, self.maxZoom)
end

function FieldZoom:zoomIn()
  self.manualZoom = clamp(self.manualZoom + self.step, self.minZoom, self.maxZoom)
end

function FieldZoom:zoomOut()
  self.manualZoom = clamp(self.manualZoom - self.step, self.minZoom, self.maxZoom)
end

function FieldZoom:reset()
  self.manualZoom = self.defaultManualZoom
end

return FieldZoom
