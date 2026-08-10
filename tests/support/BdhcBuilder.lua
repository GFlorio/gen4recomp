-- Builds complete synthetic HGSS BDHC payloads for decoder and terrain tests.
-- Records use the binary layout emitted by Pokemon DS Map Studio's pinned
-- BdhcWriterHGSS implementation. Test-only.

local BinaryWriter = require("libs.rom.src.BinaryWriter")

local BdhcBuilder = {}

-- The BDHC layout stores point coordinates, strip maxZ, slope normals, and
-- heights as signed values (HgssBdhc re-signs them on decode), while the
-- writer fields are unsigned. Encode negatives explicitly as two's-complement
-- instead of relying on the writer to wrap out-of-range values.
local function signedToUnsigned(value, bits)
  return value % 2 ^ bits
end

local function writePoint(w, point)
  w:u16(point.raw0 or 0):u16(signedToUnsigned(point.x, 16)):u16(point.raw4 or 0):u16(signedToUnsigned(point.z, 16))
end

local function writeSlope(w, slope)
  w:u32(signedToUnsigned(slope.nx, 32)):u32(signedToUnsigned(slope.ny, 32)):u32(signedToUnsigned(slope.nz, 32))
end

local function writePlate(w, plate)
  w:u16(plate.minPointIndex):u16(plate.maxPointIndex):u16(plate.slopeIndex):u16(plate.heightIndex)
end

local function writeStrip(w, strip)
  w:u16(strip.reserved or 0):u16(signedToUnsigned(strip.maxZ, 16)):u16(strip.accessCount):u16(strip.accessStart)
end

function BdhcBuilder.heightRaw(distance)
  local raw = -distance * 65536
  return raw < 0 and math.ceil(raw - 0.5) or math.floor(raw + 0.5)
end

function BdhcBuilder.build(opts)
  opts = opts or {}
  local points = opts.points or {
    { x = -16, z = -16 },
    { x = 16, z = 16 },
  }
  local slopes = opts.slopes or { { nx = 0, ny = 4096, nz = 0 } }
  local heights = opts.heights or { BdhcBuilder.heightRaw(0) }
  local plates = opts.plates or {
    { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
  }
  local strips = opts.strips or {
    { maxZ = 16, accessStart = 0, accessCount = #plates },
  }
  local accessEntries = opts.accessEntries
  if not accessEntries then
    accessEntries = {}
    for plateId = 0, #plates - 1 do
      accessEntries[#accessEntries + 1] = plateId
    end
  end

  local w = BinaryWriter.new()
  w:bytes(opts.magic or "BDHC"):u16(#points):u16(#slopes):u16(#heights):u16(#plates):u16(#strips):u16(#accessEntries)
  for _, point in ipairs(points) do
    writePoint(w, point)
  end
  for _, slope in ipairs(slopes) do
    writeSlope(w, slope)
  end
  for _, height in ipairs(heights) do
    w:u32(signedToUnsigned(height, 32))
  end
  for _, plate in ipairs(plates) do
    writePlate(w, plate)
  end
  for _, strip in ipairs(strips) do
    writeStrip(w, strip)
  end
  for _, plateId in ipairs(accessEntries) do
    w:u16(plateId)
  end
  return w:tostring()
end

return BdhcBuilder
