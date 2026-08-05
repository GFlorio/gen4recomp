-- Computes the matrix cells touched by a field-camera frustum inside a bounded
-- terrain-height envelope. It is pure: callers own map loading and use the
-- returned zero-based cell list to protect visible and prefetched resources.

local Errors = require("libs.rom.src.Errors")

local FieldCoveragePlanner = {}

local function components(v)
  return v.x or v[1], v.y or v[2], v.z or v[3]
end

local function add(a, b, scale)
  scale = scale or 1
  local ax, ay, az = components(a)
  local bx, by, bz = components(b)
  return { ax + bx * scale, ay + by * scale, az + bz * scale }
end

local function subtract(a, b)
  local ax, ay, az = components(a)
  local bx, by, bz = components(b)
  return { ax - bx, ay - by, az - bz }
end

local function dot(a, b)
  local ax, ay, az = components(a)
  local bx, by, bz = components(b)
  return ax * bx + ay * by + az * bz
end

local function cross(a, b)
  local ax, ay, az = components(a)
  local bx, by, bz = components(b)
  return {
    ay * bz - az * by,
    az * bx - ax * bz,
    ax * by - ay * bx,
  }
end

local function normalize(v)
  local length = math.sqrt(dot(v, v))
  assert(length > 0, "camera direction must be non-zero")
  return { v[1] / length, v[2] / length, v[3] / length }
end

local function planeCorners(camera, distance)
  local profile = camera.profile
  local forward = normalize(subtract(camera.target, camera.eye))
  local right = normalize(cross(forward, camera.up))
  local up = cross(right, forward)
  local halfY
  if profile.projectionType == "perspective" then
    halfY = math.tan(profile.fullVerticalFovRadians / 2) * distance
  elseif profile.projectionType == "orthographic" then
    halfY = math.tan(profile.halfFovRadians) * profile.distanceTiles
  else
    error("unknown field projection " .. tostring(profile.projectionType))
  end
  local zoom = camera.zoom or 1
  assert(zoom > 0, "camera zoom must be positive")
  halfY = halfY / zoom
  local halfX = halfY * camera.projectionAspect
  local center = add(camera.eye, forward, distance)
  return {
    add(add(center, right, -halfX), up, -halfY),
    add(add(center, right, halfX), up, -halfY),
    add(add(center, right, halfX), up, halfY),
    add(add(center, right, -halfX), up, halfY),
  }
end

local function frustumCorners(camera)
  local near = planeCorners(camera, camera.profile.nearTiles)
  local far = planeCorners(camera, camera.profile.farTiles)
  return {
    near[1], near[2], near[3], near[4],
    far[1], far[2], far[3], far[4],
  }
end

local EDGES = {
  { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
  { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
  { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
}

-- Project the clipped frustum volume onto X/Z after intersecting it with the
-- inclusive Y slab. This handles flat maps (minY == maxY) and slopes alike.
function FieldCoveragePlanner.frustumGroundBounds(camera, envelope)
  assert(camera and camera.profile, "camera profile required")
  assert(envelope and envelope.minY <= envelope.maxY, "valid height envelope required")
  local corners = frustumCorners(camera)
  local points = {}

  for _, point in ipairs(corners) do
    if point[2] >= envelope.minY and point[2] <= envelope.maxY then
      points[#points + 1] = point
    end
  end

  local planes = envelope.minY == envelope.maxY
    and { envelope.minY } or { envelope.minY, envelope.maxY }
  for _, edge in ipairs(EDGES) do
    local a, b = corners[edge[1]], corners[edge[2]]
    local dy = b[2] - a[2]
    if dy ~= 0 then
      for _, y in ipairs(planes) do
        local t = (y - a[2]) / dy
        if t >= 0 and t <= 1 then points[#points + 1] = add(a, subtract(b, a), t) end
      end
    end
  end

  if #points == 0 then
    Errors.raise("FIELD_COVERAGE_INCOMPLETE",
      "camera frustum does not intersect the terrain height envelope", envelope)
  end

  local bounds = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
  for _, point in ipairs(points) do
    bounds.minX = math.min(bounds.minX, point[1])
    bounds.maxX = math.max(bounds.maxX, point[1])
    bounds.minZ = math.min(bounds.minZ, point[3])
    bounds.maxZ = math.max(bounds.maxZ, point[3])
  end
  return bounds
end

function FieldCoveragePlanner.planBounds(bounds, opts)
  assert(opts.matrixWidth > 0 and opts.matrixHeight > 0, "matrix dimensions must be positive")
  local cellSize = opts.cellSize or 32
  local margin = opts.prefetchMargin or 1
  assert(cellSize > 0 and margin >= 0 and margin == math.floor(margin), "invalid coverage scale")
  local originX, originZ = opts.worldOriginX or 0, opts.worldOriginZ or 0
  local minX = math.floor((bounds.minX - originX) / cellSize) - margin
  local maxX = math.floor((bounds.maxX - originX) / cellSize) + margin
  local minZ = math.floor((bounds.minZ - originZ) / cellSize) - margin
  local maxZ = math.floor((bounds.maxZ - originZ) / cellSize) + margin
  minX, minZ = math.max(0, minX), math.max(0, minZ)
  maxX, maxZ = math.min(opts.matrixWidth - 1, maxX), math.min(opts.matrixHeight - 1, maxZ)

  local cells = {}
  if minX <= maxX and minZ <= maxZ then
    for z = minZ, maxZ do
      for x = minX, maxX do cells[#cells + 1] = { x = x, z = z } end
    end
  end
  return {
    worldBounds = bounds,
    cellBounds = { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ },
    cells = cells,
  }
end

function FieldCoveragePlanner.plan(camera, envelope, opts)
  return FieldCoveragePlanner.planBounds(
    FieldCoveragePlanner.frustumGroundBounds(camera, envelope), opts)
end

-- `available` is keyed as "x:z". Keeping ownership outside this module lets a
-- loader decide whether a missing cell should be loaded, excluded, or fatal.
function FieldCoveragePlanner.assertAvailable(plan, available)
  for _, cell in ipairs(plan.cells) do
    if not available[cell.x .. ":" .. cell.z] then
      Errors.raise("FIELD_COVERAGE_INCOMPLETE", "planned field cell is not loaded",
        { x = cell.x, z = cell.z })
    end
  end
  return true
end

return FieldCoveragePlanner
