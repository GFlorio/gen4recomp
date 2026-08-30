-- FieldZoom tests the configurable split between pixel growth and automatic
-- projection zoom as the host drawable changes height.

local Assert = require("tests.support.Assert")
local FieldZoom = require("libs.hgss.src.presentation.FieldZoom")

local T = {}
local function approx(a, b)
  return math.abs(a - b) < 1e-9
end

function T.resize_compensation_endpoints_are_predictable()
  local fixed = FieldZoom.new({ referenceHeight = 720, resizeCompensation = 0 })
  fixed:resize(1080)
  Assert.equal(fixed:effectiveZoom(), 1)

  local compensated = FieldZoom.new({ referenceHeight = 720, resizeCompensation = 1 })
  compensated:resize(1080)
  Assert.isTrue(approx(compensated:effectiveZoom(), 2 / 3))
end

function T.partial_compensation_and_manual_zoom_compose_then_clamp()
  local zoom = FieldZoom.new({
    referenceHeight = 720,
    resizeCompensation = 0.5,
    minZoom = 0.75,
    maxZoom = 1.25,
    manualZoom = 1.2,
    step = 0.1,
  })
  zoom:resize(1080)
  Assert.isTrue(approx(zoom:effectiveZoom(), 1.2 * math.sqrt(2 / 3)))
  zoom:zoomIn()
  Assert.isTrue(approx(zoom.manualZoom, 1.25))
  zoom:zoomOut()
  Assert.isTrue(approx(zoom.manualZoom, 1.15))
  zoom:reset()
  Assert.equal(zoom.manualZoom, 1.2)
end

function T.effective_zoom_respects_constraints_after_resize()
  local zoom = FieldZoom.new({
    referenceHeight = 720,
    resizeCompensation = 1,
    minZoom = 0.5,
    maxZoom = 2,
  })
  zoom:resize(2160)
  Assert.equal(zoom:effectiveZoom(), 0.5)
  zoom:resize(180)
  Assert.equal(zoom:effectiveZoom(), 2)
end

function T.invalid_configuration_is_rejected()
  Assert.throws(function()
    FieldZoom.new({ resizeCompensation = 1.1 })
  end)
  Assert.throws(function()
    FieldZoom.new({ minZoom = 2, maxZoom = 1 })
  end)
  Assert.throws(function()
    FieldZoom.new({ referenceHeight = 0 })
  end)
end

return { tests = T }
