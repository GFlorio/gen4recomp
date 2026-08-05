-- Camera3D placement: the eye sits on a sphere around the target at the fixed
-- yaw/pitch/distance, and a profile seeds the lens.

local Assert = require("tests.support.Assert")
local Camera3D = require("libs.engine.src.Camera3D")

local function approx(a, b) return math.abs(a - b) < 1e-6 end

return {
  ["eye sits on the target sphere at the set distance"] = function()
    local cam = Camera3D.new({ target = { 5, 0, 5 }, yaw = 0, pitch = 0, distance = 10 })
    local e = cam:eye()
    -- yaw 0, pitch 0 -> straight along +Z from the target.
    Assert.isTrue(approx(e[1], 5) and approx(e[2], 0) and approx(e[3], 15), "eye on +Z")
  end,

  ["pitch raises the eye"] = function()
    local cam = Camera3D.new({ target = { 0, 0, 0 }, yaw = 0, pitch = math.rad(90), distance = 8 })
    local e = cam:eye()
    Assert.isTrue(approx(e[2], 8), "pitch 90 puts eye straight above")
  end,

  ["fromProfile seeds lens and angle"] = function()
    local cam = Camera3D.fromProfile({
      perspectiveDegrees = 35, distanceTiles = 18, elevationDegrees = 50, yawDegrees = 0,
    }, { 16, 0, 16 }, 1.6)
    Assert.equal(cam.distance, 18)
    Assert.isTrue(approx(cam.pitch, math.rad(50)))
    Assert.isTrue(approx(cam.fovY, math.rad(35)))
    Assert.equal(cam.aspect, 1.6)
  end,
}
