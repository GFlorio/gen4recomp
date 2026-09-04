-- FieldCamera is the pure gameplay camera for ROM-derived HGSS profiles. It
-- implements the camera behavior recovered in pret/pokeheartgold's camera.c and
-- field overlay 1 while routing Y movement through the original history ring.
-- Each fixed update keeps the previous eye/target so `view(alpha)` can
-- interpolate between simulation states, matching the player's interpolated
-- render position at lower simulation rates.

local CameraHistory = require("libs.hgss.src.field.CameraHistory")
local Matrix4 = require("libs.math.src.Matrix4")

-- HGSS renders billboards and field effects through a depth-biased copy of the
-- projection: pokeheartgold src/field/fieldmap.c ov01_021E6220 copies the
-- active projection after drawing maps and props, bumps `_32` (the Z-row
-- translation) by `_22` (the Z-row scale) times `fieldSystem->unk11C = 8`
-- model units times cos(-camera.angle.x), draws FieldEffectManager_Render and
-- BillboardLists_Draw through it, then restores the original projection. The
-- pull lives entirely in the depth row, so billboards keep their screen
-- position and size but win depth ties against same-depth map geometry. With
-- 16 model units per tile, the 8 model units become 0.5 tiles.
local FIELD_BILLBOARD_DEPTH_OFFSET_TILES = 0.5

---@class FieldCamera
---@field cameraSourceY number
---@field cameraAppliedY number
---@field zoom number
---@field projectionType "perspective"|"orthographic"
---@field profile table<string, unknown>
---@field distance number
---@field near number
---@field far number
---@field sourceTarget { x: number, y: number, z: number }
---@field target { x: number, y: number, z: number }
---@field previousTarget { x: number, y: number, z: number }
---@field eye { x: number, y: number, z: number }
---@field previousEye { x: number, y: number, z: number }
---@field up { x: number, y: number, z: number }
---@field history table<string, unknown>
---@field historyEnabled boolean
---@field canonicalAspect number
---@field projectionAspect number
---@field _billboardDepthOffset number
---@field _projectionDirty boolean
---@field _projectionCache number[]|nil
---@field _billboardProjectionCache number[]|nil
local FieldCamera = {}
FieldCamera.__index = FieldCamera

local TAU = 2 * math.pi

local function copyVector(vector)
  assert(type(vector) == "table", "camera vector must be a table")
  assert(
    type(vector.x) == "number" and type(vector.y) == "number" and type(vector.z) == "number",
    "camera vector must contain numeric x, y, and z"
  )
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
  assert(
    profile.projectionType == "perspective" or profile.projectionType == "orthographic",
    "unsupported camera projection type"
  )
  assert(type(profile.distanceTiles) == "number" and profile.distanceTiles > 0, "camera distance must be positive")
  assert(type(profile.angleXRaw) == "number" and type(profile.angleYRaw) == "number", "camera angles are required")
  assert(type(profile.halfFovRadians) == "number" and profile.halfFovRadians > 0, "camera half FOV is required")
  assert(
    type(profile.fullVerticalFovRadians) == "number" and profile.fullVerticalFovRadians > 0,
    "camera full vertical FOV is required"
  )
  assert(
    type(profile.nearTiles) == "number"
      and type(profile.farTiles) == "number"
      and profile.nearTiles > 0
      and profile.farTiles > profile.nearTiles,
    "invalid camera clipping planes"
  )
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
    _billboardDepthOffset = FIELD_BILLBOARD_DEPTH_OFFSET_TILES * math.cos(angleIndexToRadians(profile.angleXRaw)),
    _projectionDirty = true,
    _projectionCache = nil,
    _billboardProjectionCache = nil,
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

-- Translate the local coordinate frame after physical coverage changes. This
-- is a coordinate-system event, not terrain motion, so it never writes the Y
-- history ring.
function FieldCamera:rebase(deltaX, deltaY, deltaZ)
  assert(
    type(deltaX) == "number" and type(deltaY) == "number" and type(deltaZ) == "number",
    "camera rebase delta required"
  )
  for _, vector in ipairs({ self.sourceTarget, self.target, self.previousTarget, self.eye, self.previousEye }) do
    vector.x = vector.x + deltaX
    vector.y = vector.y + deltaY
    vector.z = vector.z + deltaZ
  end
  self.cameraSourceY = self.cameraSourceY + deltaY
  self.cameraAppliedY = self.cameraAppliedY + deltaY
end

function FieldCamera:setProjectionAspect(aspect)
  assert(type(aspect) == "number" and aspect > 0, "projection aspect must be positive")
  if self.projectionAspect == aspect then
    return
  end
  self.projectionAspect = aspect
  self._projectionDirty = true
end

function FieldCamera:setZoom(zoom)
  assert(type(zoom) == "number" and zoom > 0, "camera zoom must be positive")
  if self.zoom == zoom then
    return
  end
  self.zoom = zoom
  self._projectionDirty = true
end

-- Applies the camera-side part of a non-ordinary field transition. The
-- transition family remains observable after the swap, while the camera
-- keeps ownership of its own adjustment state.
function FieldCamera:adjustTransition(profile, adjustment)
  assert(type(profile) == "number", "transition camera profile required")
  assert(type(adjustment) == "string", "transition camera adjustment required")
  local sourceTarget = self.sourceTarget
  if self.transitionPlayer then
    sourceTarget = copyVector(self.transitionPlayer:renderPosition())
  end
  self.sourceTarget = sourceTarget
  local offset = self.profile.targetOffsetTiles
  self.target = {
    x = sourceTarget.x + offset.x,
    y = sourceTarget.y + offset.y,
    z = sourceTarget.z + offset.z,
  }
  self.eye = eyeFromTarget(self.target, self.profile)
  self.previousTarget = copyVector(self.target)
  self.previousEye = copyVector(self.eye)
  self.cameraSourceY = sourceTarget.y
  self.cameraAppliedY = self.target.y - offset.y
  if adjustment == "cave" then
    self.perspectiveMode = "environment_0x10"
  elseif adjustment == "outdoor" then
    self.perspectiveMode = "white_fade"
  end
end

function FieldCamera:setTransitionPlayer(player)
  assert(type(player) == "table", "transition player required")
  self.transitionPlayer = player
end

function FieldCamera:collapseRenderInterpolation()
  self.previousTarget = copyVector(self.target)
  self.previousEye = copyVector(self.eye)
end

-- `alpha` is the render interpolation factor of the current fixed step: 0 shows
-- the state the previous fixed update left behind, 1 the latest one, and values
-- between are smoothed so the camera cannot jump between simulation ticks.
function FieldCamera:view(alpha)
  alpha = alpha == nil and 1 or math.max(0, math.min(1, alpha))
  local eye = lerpVector(self.previousEye, self.eye, alpha)
  local target = lerpVector(self.previousTarget, self.target, alpha)
  return Matrix4.lookAt({ eye.x, eye.y, eye.z }, { target.x, target.y, target.z }, { self.up.x, self.up.y, self.up.z })
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

function FieldCamera:_refreshProjectionCache()
  if not self._projectionDirty then
    return
  end

  local projection = self:_projection(self.projectionAspect, self.zoom)
  local billboardProjection = Matrix4.toArray(projection)
  billboardProjection[15] = billboardProjection[15] + billboardProjection[11] * self._billboardDepthOffset

  self._projectionCache = projection
  self._billboardProjectionCache = billboardProjection
  self._projectionDirty = false
end

-- The returned matrix is persistent camera-owned state. Callers must treat it
-- as immutable and read-only until the next projection invalidation.
---@return number[] projection matrix
function FieldCamera:projection()
  self:_refreshProjectionCache()
  return self._projectionCache
end

-- The projection field billboards draw through: the normal projection with the
-- DS's fixed depth pull added to the Z-row translation. Cos is even, so
-- cos(-angleX) and cos(angleX) agree and the profile's raw pitch is enough.
-- The returned matrix is persistent camera-owned state. Callers must treat it
-- as immutable and read-only until the next projection invalidation.
---@return number[] billboard projection matrix
function FieldCamera:billboardProjection()
  self:_refreshProjectionCache()
  return self._billboardProjectionCache
end

function FieldCamera:canonicalProjection()
  return self:_projection(self.canonicalAspect, 1)
end

FieldCamera.FIELD_BILLBOARD_DEPTH_OFFSET_TILES = FIELD_BILLBOARD_DEPTH_OFFSET_TILES

return FieldCamera
