-- Produces deterministic, payload-free BDHC plate reports and project-generated
-- plane quads for diagnostics. The inspector consumes normalized terrain only;
-- it never reads ROM resources or interprets permission bytes.

local TerrainInspector = {}

local function intersects(plate, bounds)
  if not bounds then return true end
  return plate.maxX >= bounds.minX and plate.minX <= bounds.maxX
    and plate.maxZ >= bounds.minZ and plate.minZ <= bounds.maxZ
end

local function copyPlate(plate)
  return {
    id = plate.id,
    minX = plate.minX,
    minZ = plate.minZ,
    maxX = plate.maxX,
    maxZ = plate.maxZ,
    slopeIndex = plate.slopeIndex,
    heightIndex = plate.heightIndex,
    normal = { x = plate.normal.x, y = plate.normal.y, z = plate.normal.z },
    distance = plate.distance,
    slopeClass = plate.slopeClass,
    walkable = plate.walkable ~= false,
  }
end

function TerrainInspector.inspect(terrain, bounds)
  assert(type(terrain) == "table" and type(terrain.plates) == "table",
    "TerrainInspector.inspect requires normalized terrain")
  local plates = {}
  for _, plate in ipairs(terrain.plates) do
    if intersects(plate, bounds) then plates[#plates + 1] = copyPlate(plate) end
  end
  return {
    schema = terrain.schema,
    source = terrain.source,
    counts = terrain.counts or {
      points = #terrain.points,
      slopes = #terrain.slopes,
      heights = #terrain.heights,
      plates = #terrain.plates,
      strips = #terrain.strips,
      accessEntries = #terrain.accessEntries,
    },
    plates = plates,
  }
end

local function height(plate, x, z)
  return (plate.distance - plate.normal.x * x - plate.normal.z * z) / plate.normal.y
end

-- Return renderer-neutral quad records. A diagnostic renderer may turn these
-- into line or translucent triangle meshes without learning BDHC plane math.
function TerrainInspector.gizmos(terrain, plates)
  assert(type(terrain) == "table" and type(terrain.plates) == "table",
    "TerrainInspector.gizmos requires normalized terrain")
  plates = plates or terrain.plates
  local out = {}
  for _, plate in ipairs(plates) do
    if plate.walkable ~= false then
      out[#out + 1] = {
        surfaceId = plate.id,
        slopeClass = plate.slopeClass,
        corners = {
          { x = plate.minX, y = height(plate, plate.minX, plate.minZ), z = plate.minZ },
          { x = plate.maxX, y = height(plate, plate.maxX, plate.minZ), z = plate.minZ },
          { x = plate.maxX, y = height(plate, plate.maxX, plate.maxZ), z = plate.maxZ },
          { x = plate.minX, y = height(plate, plate.minX, plate.maxZ), z = plate.maxZ },
        },
      }
    end
  end
  return out
end

function TerrainInspector.lines(report)
  local c = report.counts
  local lines = { string.format("terrain\tcounts=%d/%d/%d/%d/%d/%d\tselected=%d",
    c.points, c.slopes, c.heights, c.plates, c.strips, c.accessEntries, #report.plates) }
  for _, plate in ipairs(report.plates) do
    lines[#lines + 1] = string.format(
      "plate\tid=%d\tbounds=%.3f,%.3f:%.3f,%.3f\tnormal=%.8f,%.8f,%.8f\td=%.8f\tclass=%s\twalkable=%s",
      plate.id, plate.minX, plate.minZ, plate.maxX, plate.maxZ,
      plate.normal.x, plate.normal.y, plate.normal.z, plate.distance, plate.slopeClass,
      tostring(plate.walkable))
  end
  return lines
end

return TerrainInspector
