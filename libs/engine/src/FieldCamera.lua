-- FieldCamera is the pure gameplay camera for ROM-derived HGSS profiles. It
-- implements the camera behavior recovered in pret/pokeheartgold's camera.c and
-- field overlay 1 while routing Y movement through the original history ring.
-- Each fixed update keeps the previous eye/target so `view(alpha)` can
-- interpolate between simulation states, matching the player's interpolated
-- render position at lower simulation rates.

local CameraHistory = require("libs.engine.src.CameraHistory")
local Matrix4 = require("libs.math.src.Matrix4")

local FieldCamera = {}
FieldCamera.__index = FieldCamera

local TAU = 2 * math.pi

local function copyVector(vector)
  assert(type(vector) == "table", "camera vector must be a table")
  assert(type(vector.x) == "number" and type(vector.y) == "number" and type(vector.z) == "number",
    "camera vector must contain numeric x, y, and z")
  return { x = vector.x, y = vector.y, z = vector.z }
end

local function lerpVector(a, b, alpha)
  return {
    x = a.x + (b.x - a.x) * alpha,
    y = a.y + (b.y - a.y) * alpha,
    z = a.z + (b.z - a.z) * alpha,
  }
end

local function angleIndexToRadians(raw)
  return raw * TAU / 65536
end

local function eyeFromTarget(target, profile)
  local angleX = angleIndexToRadians(profile.angleXRaw)
  local yaw = angleIndexToRadians(profile.angleYRaw)
  local horizontalDistance = profile.distanceTiles * math.cos(angleX)
  return {
    x = target.x + math.sin(yaw) * horizontalDistance,
    y = target.y + math.sin(-angleX) * profile.distanceTiles,
    z = target.z + math.cos(yaw) * horizontalDistance,
  }
end

local function validateProfile(profile)
  assert(type(profile) == "table", "camera profile is required")
  assert(profile.projectionType == "perspective" or profile.projectionType == "orthographic",
    "unsupported camera projection type")
  assert(type(profile.distanceTiles) == "number" and profile.distanceTiles > 0, "camera distance must be positive")
  assert(type(profile.angleXRaw) == "number" and type(profile.angleYRaw) == "number", "camera angles are required")
  assert(type(profile.halfFovRadians) == "number" and profile.halfFovRadians > 0, "camera half FOV is required")
  assert(type(profile.fullVerticalFovRadians) == "number" and profile.fullVerticalFovRadians > 0,
    "camera full vertical FOV is required")
  assert(type(profile.nearTiles) == "number" and type(profile.farTiles) == "number"
    and profile.nearTiles > 0 and profile.farTiles > profile.nearTiles, "invalid camera clipping planes")
  copyVector(profile.targetOffsetTiles)
end

function FieldCamera.new(profile, options)
  validateProfile(profile)
  options = options or {}
  local canonicalAspect = options.canonicalAspect or (4 / 3)
  assert(canonicalAspect > 0, "canonical aspect must be positive")
  local sourceTarget = copyVector(options.initialTarget or { x = 0, y = 0, z = 0 })
  local offset = profile.targetOffsetTiles
  local target = {
    x = sourceTarget.x + offset.x,
    y = sourceTarget.y + offset.y,
    z = sourceTarget.z + offset.z,
  }
  local eye = eyeFromTarget(target, profile)
  return setmetatable({
    profile = profile,
    projectionType = profile.projectionType,
    distance = profile.distanceTiles,
    near = profile.nearTiles,
    far = profile.farTiles,
    sourceTarget = sourceTarget,
    cameraSourceY = sourceTarget.y,
    cameraAppliedY = sourceTarget.y,
    target = target,
    previousTarget = copyVector(target),
    eye = eye,
    previousEye = copyVector(eye),
    up = { x = 0, y = 1, z = 0 },
    history = CameraHistory.new(7, 6),
    historyEnabled = options.historyEnabled ~= false,
    canonicalAspect = canonicalAspect,
    projectionAspect = canonicalAspect,
    zoom = 1,
  }, FieldCamera)
end

function FieldCamera:updateFixed(playerTarget)
  self.previousEye = copyVector(self.eye)
  self.previousTarget = copyVector(self.target)
  local current = copyVector(playerTarget)
  local deltaX = current.x - self.sourceTarget.x
  local deltaY = current.y - self.sourceTarget.y
  local deltaZ = current.z - self.sourceTarget.z
  local appliedY = self.historyEnabled and self.history:push(deltaY) or deltaY
  self.target.x = self.target.x + deltaX
  self.target.y = self.target.y + appliedY
  self.target.z = self.target.z + deltaZ
  self.eye.x = self.eye.x + deltaX
  self.eye.y = self.eye.y + appliedY
  self.eye.z = self.eye.z + deltaZ
  self.sourceTarget = current
  self.cameraSourceY = current.y
  self.cameraAppliedY = self.target.y - self.profile.targetOffsetTiles.y
end

function FieldCamera:setProjectionAspect(aspect)
  assert(type(aspect) == "number" and aspect > 0, "projection aspect must be positive")
  self.projectionAspect = aspect
end

function FieldCamera:setZoom(zoom)
  assert(type(zoom) == "number" and zoom > 0, "camera zoom must be positive")
  self.zoom = zoom
end

-- `alpha` is the render interpolation factor of the current fixed step: 0 shows
-- the state the previous fixed update left behind, 1 the latest one, and values
-- between are smoothed so the camera cannot jump between simulation ticks.
function FieldCamera:view(alpha)
  alpha = alpha == nil and 1 or math.max(0, math.min(1, alpha))
  local eye = lerpVector(self.previousEye, self.eye, alpha)
  local target = lerpVector(self.previousTarget, self.target, alpha)
  return Matrix4.lookAt(
    { eye.x, eye.y, eye.z },
    { target.x, target.y, target.z },
    { self.up.x, self.up.y, self.up.z }
  )
end

function FieldCamera:_projection(aspect, zoom)
  zoom = zoom or 1
  local projection
  if self.projectionType == "perspective" then
    projection = Matrix4.perspective(self.profile.fullVerticalFovRadians, aspect, self.near, self.far)
  else
    local halfY = math.tan(self.profile.halfFovRadians) * self.distance
    local halfX = halfY * aspect
    projection = Matrix4.orthographic(-halfX, halfX, -halfY, halfY, self.near, self.far)
  end
  projection[1] = projection[1] * zoom
  projection[6] = projection[6] * zoom
  return projection
end

function FieldCamera:projection()
  return self:_projection(self.projectionAspect, self.zoom)
end

function FieldCamera:canonicalProjection()
  return self:_projection(self.canonicalAspect, 1)
end

return FieldCamera
