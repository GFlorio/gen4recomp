-- Builds decoded terrain plate shapes for runtime surface fixtures without
-- going through the HGSS BDHC decoder. TerrainSurface.new consumes only
-- artifact.plates; this fixture mirrors BdhcBuilder's semantic inputs (points,
-- slopes, heights, plates) and produces the normalized shape HgssBdhc.decode
-- would emit, including the +16 local-edge translation. Test-only.

local TerrainFixture = {}

local CENTER_OFFSET = 16
local HEIGHT_SCALE = 65536
local CLASS_EPSILON = 1e-9

local function slopeClass(normal)
  local hasX = math.abs(normal.x) > CLASS_EPSILON
  local hasZ = math.abs(normal.z) > CLASS_EPSILON
  if not hasX and not hasZ then
    return "flat"
  end
  if hasX and not hasZ then
    return "ramp_x"
  end
  if hasZ and not hasX then
    return "ramp_z"
  end
  return "custom"
end

-- The same 16.16 raw height encoding BdhcBuilder.heightRaw produces, so call
-- sites keep passing identical semantic inputs.
function TerrainFixture.heightRaw(distance)
  local raw = -distance * HEIGHT_SCALE
  return raw < 0 and math.ceil(raw - 0.5) or math.floor(raw + 0.5)
end

function TerrainFixture.build(opts)
  opts = opts or {}
  local points = opts.points or {
    { x = -16, z = -16 },
    { x = 16, z = 16 },
  }
  local slopes = opts.slopes or { { nx = 0, ny = 4096, nz = 0 } }
  local heights = opts.heights or { TerrainFixture.heightRaw(0) }
  local plates = opts.plates or {
    { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
  }

  local localPoints = {}
  for index, point in ipairs(points) do
    localPoints[index] = { x = point.x + CENTER_OFFSET, z = point.z + CENTER_OFFSET }
  end

  local normals = {}
  for index, slope in ipairs(slopes) do
    local length = math.sqrt(slope.nx * slope.nx + slope.ny * slope.ny + slope.nz * slope.nz)
    assert(length > 0, "slope normal has no direction")
    normals[index] = { x = slope.nx / length, y = slope.ny / length, z = slope.nz / length }
  end

  local distances = {}
  for index, raw in ipairs(heights) do
    distances[index] = -raw / HEIGHT_SCALE
  end

  local decoded = {}
  for id, plate in ipairs(plates) do
    local minPoint = localPoints[plate.minPointIndex + 1]
    local maxPoint = localPoints[plate.maxPointIndex + 1]
    local normal = normals[plate.slopeIndex + 1]
    decoded[id] = {
      id = id - 1,
      minX = minPoint.x,
      minZ = minPoint.z,
      maxX = maxPoint.x,
      maxZ = maxPoint.z,
      normal = normal,
      -- Translating centered source coordinates by +16 changes the plane
      -- constant: n.(p + offset) = d + n.offset.
      distance = distances[plate.heightIndex + 1] + normal.x * CENTER_OFFSET + normal.z * CENTER_OFFSET,
      slopeClass = slopeClass(normal),
      walkable = minPoint.x < maxPoint.x and minPoint.z < maxPoint.z,
    }
  end

  return { plates = decoded }
end

return TerrainFixture
