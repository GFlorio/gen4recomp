-- CameraHistory reproduces HGSS's seven-entry Y-delta ring: live while the
-- ring is primed, then delayed by six fixed updates.

local Assert = require("tests.support.Assert")
local CameraHistory = require("libs.engine.src.CameraHistory")

local T = {}

function T.first_seven_deltas_are_live()
  local history = CameraHistory.new(7, 6)
  for delta = 1, 7 do
    Assert.equal(history:push(delta), delta)
  end
end

function T.eighth_delta_uses_the_delta_from_six_updates_earlier()
  local history = CameraHistory.new(7, 6)
  for delta = 1, 7 do
    history:push(delta)
  end
  Assert.equal(history:push(8), 2)
  Assert.equal(history:push(9), 3)
end

function T.reset_restores_priming_behavior()
  local history = CameraHistory.new(7, 6)
  for delta = 1, 8 do
    history:push(delta)
  end
  history:reset()
  Assert.equal(history:push(20), 20)
end

function T.invalid_ring_configuration_is_rejected()
  Assert.throws(function()
    CameraHistory.new(0, 0)
  end)
  Assert.throws(function()
    CameraHistory.new(7, 7)
  end)
end

return T
