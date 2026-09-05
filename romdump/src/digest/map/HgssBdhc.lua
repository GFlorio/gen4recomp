-- Decodes the complete HGSS BDHC terrain container into centered source data
-- and runtime +Y-up planes. Layout and the signed 16.16 height conversion are
-- from Pokemon DS Map Studio's BdhcLoaderHGSS/BdhcWriterHGSS at the project pin.
-- Pure domain module; decode() returns (terrain | nil, err).

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")

local HgssBdhc = {}

local HEADER_SIZE = 0x10
local POINT_SIZE = 0x08
local SLOPE_SIZE = 0x0C
local HEIGHT_SIZE = 0x04
local PLATE_SIZE = 0x08
local STRIP_SIZE = 0x08
local ACCESS_SIZE = 0x02
local CENTER_OFFSET = 16
local HEIGHT_SCALE = 65536
local CLASS_EPSILON = 1e-9

local function signed(value, bits)
  local high = 2 ^ (bits - 1)
  return value >= high and value - 2 ^ bits or value
end

local function fail(code, message, context)
  Errors.raise(code, message, context)
end

local function requireIndex(value, count, field, recordId, context)
  if value < 0 or value >= count then
    fail(
      "BDHC_INDEX_OUT_OF_RANGE",
      string.format("%s %d on record %d is outside zero-based count %d", field, value, recordId, count),
      { source = context, field = field, recordId = recordId, index = value, count = count }
    )
  end
end

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

local function parse(bytes, context)
  if #bytes < HEADER_SIZE then
    fail("BDHC_TRUNCATED", "BDHC header is truncated", { source = context, expected = HEADER_SIZE, actual = #bytes })
  end
  local r = BinaryReader.new(bytes, "HGSS BDHC")
  local magic = r:bytes(0, 4)
  if magic ~= "BDHC" then
    fail(
      "BDHC_BAD_MAGIC",
      "BDHC magic is " .. string.format("%q", magic),
      { source = context, offset = 0, expected = "BDHC", actual = magic }
    )
  end

  local counts = {
    points = r:u16le(0x04),
    slopes = r:u16le(0x06),
    heights = r:u16le(0x08),
    plates = r:u16le(0x0A),
    strips = r:u16le(0x0C),
    accessEntries = r:u16le(0x0E),
  }
  local pointOffset = HEADER_SIZE
  local slopeOffset = pointOffset + counts.points * POINT_SIZE
  local heightOffset = slopeOffset + counts.slopes * SLOPE_SIZE
  local plateOffset = heightOffset + counts.heights * HEIGHT_SIZE
  local stripOffset = plateOffset + counts.plates * PLATE_SIZE
  local accessOffset = stripOffset + counts.strips * STRIP_SIZE
  local expectedEnd = accessOffset + counts.accessEntries * ACCESS_SIZE
  if expectedEnd > #bytes then
    fail(
      "BDHC_TRUNCATED",
      "BDHC arrays extend beyond the payload",
      { source = context, expected = expectedEnd, actual = #bytes }
    )
  end
  if expectedEnd < #bytes then
    fail(
      "BDHC_TRAILING_BYTES",
      "BDHC has undocumented trailing bytes",
      { source = context, offset = expectedEnd, trailing = #bytes - expectedEnd }
    )
  end

  local points = {}
  for id = 0, counts.points - 1 do
    local offset = pointOffset + id * POINT_SIZE
    local x = signed(r:u16le(offset + 2), 16)
    local z = signed(r:u16le(offset + 6), 16)
    points[id + 1] = {
      id = id,
      raw0 = r:u16le(offset),
      x = x,
      raw4 = r:u16le(offset + 4),
      z = z,
      localEdgeX = x + CENTER_OFFSET,
      localEdgeZ = z + CENTER_OFFSET,
    }
  end

  local slopes = {}
  for id = 0, counts.slopes - 1 do
    local offset = slopeOffset + id * SLOPE_SIZE
    local nxRaw = signed(r:u32le(offset), 32)
    local nyRaw = signed(r:u32le(offset + 4), 32)
    local nzRaw = signed(r:u32le(offset + 8), 32)
    local length = math.sqrt(nxRaw * nxRaw + nyRaw * nyRaw + nzRaw * nzRaw)
    if length == 0 then
      fail("BDHC_NORMAL_ZERO", "slope normal has no direction", { source = context, slopeId = id, offset = offset })
    end
    slopes[id + 1] = {
      id = id,
      nxRaw = nxRaw,
      nyRaw = nyRaw,
      nzRaw = nzRaw,
      normal = { x = nxRaw / length, y = nyRaw / length, z = nzRaw / length },
    }
  end

  local heights = {}
  for id = 0, counts.heights - 1 do
    local raw = signed(r:u32le(heightOffset + id * HEIGHT_SIZE), 32)
    heights[id + 1] = { id = id, raw = raw, distance = -raw / HEIGHT_SCALE }
  end

  local plates = {}
  for id = 0, counts.plates - 1 do
    local offset = plateOffset + id * PLATE_SIZE
    local minPointIndex = r:u16le(offset)
    local maxPointIndex = r:u16le(offset + 2)
    local slopeIndex = r:u16le(offset + 4)
    local heightIndex = r:u16le(offset + 6)
    requireIndex(minPointIndex, counts.points, "minPointIndex", id, context)
    requireIndex(maxPointIndex, counts.points, "maxPointIndex", id, context)
    requireIndex(slopeIndex, counts.slopes, "slopeIndex", id, context)
    requireIndex(heightIndex, counts.heights, "heightIndex", id, context)
    local minPoint = points[minPointIndex + 1]
    local maxPoint = points[maxPointIndex + 1]
    if minPoint.localEdgeX > maxPoint.localEdgeX or minPoint.localEdgeZ > maxPoint.localEdgeZ then
      fail(
        "BDHC_BOUNDS_REVERSED",
        "plate minimum point exceeds its maximum point",
        { source = context, plateId = id, minPointIndex = minPointIndex, maxPointIndex = maxPointIndex }
      )
    end
    local slope = slopes[slopeIndex + 1]
    local height = heights[heightIndex + 1]
    local walkable = minPoint.localEdgeX < maxPoint.localEdgeX and minPoint.localEdgeZ < maxPoint.localEdgeZ
    if walkable and slope.normal.y == 0 then
      fail(
        "BDHC_VERTICAL_NORMAL_ZERO",
        "walkable plane has a zero vertical normal",
        { source = context, plateId = id, slopeId = slopeIndex, offset = offset }
      )
    end
    -- Translating centered source coordinates by +16 changes the plane
    -- constant: n.(p + offset) = d + n.offset.
    local localDistance = height.distance + slope.normal.x * CENTER_OFFSET + slope.normal.z * CENTER_OFFSET
    plates[id + 1] = {
      id = id,
      minPointIndex = minPointIndex,
      maxPointIndex = maxPointIndex,
      slopeIndex = slopeIndex,
      heightIndex = heightIndex,
      minX = minPoint.localEdgeX,
      minZ = minPoint.localEdgeZ,
      maxX = maxPoint.localEdgeX,
      maxZ = maxPoint.localEdgeZ,
      normal = { x = slope.normal.x, y = slope.normal.y, z = slope.normal.z },
      distance = localDistance,
      slopeClass = slopeClass(slope.normal),
      walkable = walkable,
    }
  end

  local accessEntries = {}
  for index = 0, counts.accessEntries - 1 do
    local plateId = r:u16le(accessOffset + index * ACCESS_SIZE)
    requireIndex(plateId, counts.plates, "accessEntry", index, context)
    accessEntries[index + 1] = plateId
  end

  local strips = {}
  for id = 0, counts.strips - 1 do
    local offset = stripOffset + id * STRIP_SIZE
    local accessCount = r:u16le(offset + 4)
    local accessStart = r:u16le(offset + 6)
    if accessStart + accessCount > counts.accessEntries then
      fail("BDHC_ACCESS_RANGE_INVALID", "strip access range exceeds the access array", {
        source = context,
        stripId = id,
        accessStart = accessStart,
        accessCount = accessCount,
        accessEntryCount = counts.accessEntries,
      })
    end
    local entries = {}
    for index = accessStart, accessStart + accessCount - 1 do
      entries[#entries + 1] = accessEntries[index + 1]
    end
    strips[id + 1] = {
      id = id,
      reserved = r:u16le(offset),
      maxZ = signed(r:u16le(offset + 2), 16),
      accessCount = accessCount,
      accessStart = accessStart,
      accessEntries = entries,
    }
  end

  return {
    schema = "hgss-bdhc-v1",
    source = context,
    counts = counts,
    points = points,
    slopes = slopes,
    heights = heights,
    plates = plates,
    strips = strips,
    accessEntries = accessEntries,
  }
end

function HgssBdhc.decode(bytes, context)
  assert(type(bytes) == "string", "HgssBdhc.decode requires a string")
  local ok, result = pcall(parse, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return HgssBdhc
