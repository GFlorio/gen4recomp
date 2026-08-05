-- Decodes the exact 36-byte HGSS field-camera records consumed by field
-- overlay 1. The layout follows pret/pokeheartgold's recovered camera assembly;
-- raw Nitro fx32 and angle-index values are preserved beside runtime units.

local BinaryReader = require("libs.rom.src.BinaryReader")
local Errors = require("libs.rom.src.Errors")

local HgssCameraTable = {}
local RECORD_SIZE = 0x24
local FX32_PER_TILE = 4096 * 16

local function signed(value, modulus)
  local half = modulus / 2
  return value >= half and value - modulus or value
end

local function angleDegrees(value)
  return value * 360 / 65536
end

local function tiles(value)
  return value / FX32_PER_TILE
end

local function _decode(bytes, options)
  assert(type(bytes) == "string", "decode requires overlay bytes")
  assert(type(options) == "table", "decode requires options")
  local tableOffset = assert(options.tableOffset, "tableOffset is required")
  local recordCount = assert(options.recordCount, "recordCount is required")
  local source = options.source or "hgss-camera-table"
  local byteLength = recordCount * RECORD_SIZE
  if tableOffset < 0 or tableOffset + byteLength > #bytes then
    Errors.raise("FIELD_CAMERA_TABLE_OUT_OF_BOUNDS",
      string.format("%d camera records at 0x%X exceed %d-byte %s",
        recordCount, tableOffset, #bytes, source),
      { tableOffset = tableOffset, recordCount = recordCount,
        recordSize = RECORD_SIZE, overlayByteLength = #bytes, source = source })
  end

  local reader = BinaryReader.new(bytes, source)
  local records = {}
  for cameraType = 0, recordCount - 1 do
    local base = tableOffset + cameraType * RECORD_SIZE
    local projectionTypeRaw = reader:u8(base + 0x0C)
    if projectionTypeRaw ~= 0 and projectionTypeRaw ~= 1 then
      Errors.raise("FIELD_CAMERA_PROJECTION_UNKNOWN",
        "camera type " .. cameraType .. " has projection type " .. projectionTypeRaw,
        { cameraType = cameraType, projectionTypeRaw = projectionTypeRaw, source = source })
    end
    local distanceRaw = reader:u32le(base)
    local angleXRaw = signed(reader:u16le(base + 0x04), 65536)
    local angleYRaw = signed(reader:u16le(base + 0x06), 65536)
    local angleZRaw = signed(reader:u16le(base + 0x08), 65536)
    local perspectiveHalfAngleRaw = reader:u16le(base + 0x0E)
    local nearRaw = reader:u32le(base + 0x10)
    local farRaw = reader:u32le(base + 0x14)
    local offsetXRaw = signed(reader:u32le(base + 0x18), 4294967296)
    local offsetYRaw = signed(reader:u32le(base + 0x1C), 4294967296)
    local offsetZRaw = signed(reader:u32le(base + 0x20), 4294967296)
    local halfFovDegrees = angleDegrees(perspectiveHalfAngleRaw)
    local projection = projectionTypeRaw == 0 and "perspective" or "orthographic"
    local halfFovRadians = perspectiveHalfAngleRaw * 2 * math.pi / 65536
    records[cameraType] = {
      cameraType = cameraType,
      raw = {
        distanceRaw = distanceRaw,
        angleXRaw = angleXRaw,
        angleYRaw = angleYRaw,
        angleZRaw = angleZRaw,
        unknownAngleField = signed(reader:u16le(base + 0x0A), 65536),
        projectionTypeRaw = projectionTypeRaw,
        unknownByte = reader:u8(base + 0x0D),
        perspectiveHalfAngleRaw = perspectiveHalfAngleRaw,
        nearRaw = nearRaw,
        farRaw = farRaw,
        offsetXRaw = offsetXRaw,
        offsetYRaw = offsetYRaw,
        offsetZRaw = offsetZRaw,
      },
      projection = projection,
      projectionType = projection,
      angleXRaw = angleXRaw,
      angleYRaw = angleYRaw,
      angleZRaw = angleZRaw,
      distanceTiles = tiles(distanceRaw),
      angleXDegrees = angleDegrees(angleXRaw),
      elevationDegrees = -angleDegrees(angleXRaw),
      yawDegrees = angleDegrees(angleYRaw),
      rollDegrees = angleDegrees(angleZRaw),
      halfFovDegrees = halfFovDegrees,
      fullVerticalFovDegrees = halfFovDegrees * 2,
      halfFovRadians = halfFovRadians,
      fullVerticalFovRadians = halfFovRadians * 2,
      nearTiles = tiles(nearRaw),
      farTiles = tiles(farRaw),
      targetOffsetTiles = {
        x = tiles(offsetXRaw), y = tiles(offsetYRaw), z = tiles(offsetZRaw),
      },
    }
  end
  return {
    schema = "hgss-field-camera-table-v1",
    source = source,
    recordCount = recordCount,
    records = records,
  }
end

function HgssCameraTable.decode(bytes, options)
  local ok, result = pcall(_decode, bytes, options)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return HgssCameraTable
