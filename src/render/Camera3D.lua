-- Orbit camera over a target tile, producing the view and projection matrices
-- the map shader consumes. State is a target point plus yaw/pitch/distance and
-- lens parameters; view() places the eye on a sphere around the target and
-- looks back at it, projection() is a right-handed perspective. Two ways in:
-- the free diagnostic camera drives yaw/pitch/distance directly; fromProfile()
-- seeds those from a checked-in provisional camera profile (elevation/yaw/
-- distance/target-height in tile units). Pure domain module (uses Matrix4, no
-- love). Provisional profiles are explicitly not the DS camera table.

local Matrix4 = require("src.render.Matrix4")

local Camera3D = {}
Camera3D.__index = Camera3D

local function rad(deg) return deg * math.pi / 180 end

function Camera3D.new(opts)
  opts = opts or {}
  return setmetatable({
    target = opts.target or { 0, 0, 0 },
    yaw = opts.yaw or 0,        -- radians, around +Y
    pitch = opts.pitch or rad(50), -- radians, above the horizon
    distance = opts.distance or 18,
    fovY = opts.fovY or rad(35),
    near = opts.near or 0.1,
    far = opts.far or 400,
    aspect = opts.aspect or 1,
  }, Camera3D)
end

-- Seed an orbit camera from a provisional camera_profiles.lua record.
function Camera3D.fromProfile(profile, target, aspect)
  return Camera3D.new({
    target = target,
    yaw = rad(profile.yawDegrees or 0),
    pitch = rad(profile.elevationDegrees or 50),
    distance = profile.distanceTiles or 18,
    fovY = rad(profile.perspectiveDegrees or 35),
    aspect = aspect or 1,
  })
end

function Camera3D:setAspect(aspect)
  self.aspect = aspect
end

-- Clamp pitch just shy of straight down/up so lookAt's up vector never degenerates.
function Camera3D:orbit(dYaw, dPitch)
  self.yaw = self.yaw + dYaw
  local limit = math.pi / 2 - 0.01
  self.pitch = math.max(-limit, math.min(limit, self.pitch + dPitch))
end

function Camera3D:zoom(factor)
  self.distance = math.max(1, self.distance * factor)
end

function Camera3D:pan(dx, dz)
  self.target[1] = self.target[1] + dx
  self.target[3] = self.target[3] + dz
end

function Camera3D:eye()
  local cp = math.cos(self.pitch)
  return {
    self.target[1] + self.distance * cp * math.sin(self.yaw),
    self.target[2] + self.distance * math.sin(self.pitch),
    self.target[3] + self.distance * cp * math.cos(self.yaw),
  }
end

function Camera3D:view()
  return Matrix4.lookAt(self:eye(), self.target, { 0, 1, 0 })
end

function Camera3D:projection()
  return Matrix4.perspective(self.fovY, self.aspect, self.near, self.far)
end

return Camera3D
