-- Smoke decoder for a map-matrix NARC member, proving runtime code can consume
-- a NARC member using a layout recovered from the decompilation's
-- src/map_matrix.c. Pure domain module. Header and altitude sections
-- are optional; absent sections fall back to a default map-header id and zero
-- altitude. All logical accessors are zero-based even though Lua storage is
-- 1-based arrays. decode() returns (matrix | nil, err) like other parsers.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")

local MapMatrix = {}
MapMatrix.__index = MapMatrix

local MAX_CELLS = 799
local MAX_NAME = 16

local function finiteInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

local function readFlag(reader, offset, field)
  local v = reader:u8(offset)
  if v ~= 0 and v ~= 1 then
    Errors.raise(
      "MAP_MATRIX_BAD_FLAG",
      field .. " section flag must be 0 or 1, got " .. v,
      { field = field, value = v }
    )
  end
  return v == 1
end

local function parse(data, defaultMapHeaderId)
  defaultMapHeaderId = defaultMapHeaderId or 0
  local reader = BinaryReader.new(data, "map-matrix")

  local width = reader:u8(0)
  local height = reader:u8(1)
  if width == 0 or height == 0 then
    Errors.raise("MAP_MATRIX_EMPTY", "width and height must both be nonzero", { width = width, height = height })
  end
  local cellCount = width * height
  if cellCount > MAX_CELLS then
    Errors.raise(
      "MAP_MATRIX_TOO_LARGE",
      "cell count " .. cellCount .. " exceeds matrix capacity " .. MAX_CELLS,
      { width = width, height = height, cellCount = cellCount }
    )
  end

  local hasHeaders = readFlag(reader, 2, "hasHeaders")
  local hasAltitudes = readFlag(reader, 3, "hasAltitudes")
  local nameLength = reader:u8(4)
  if nameLength > MAX_NAME then
    Errors.raise(
      "MAP_MATRIX_NAME_TOO_LONG",
      "name length " .. nameLength .. " exceeds " .. MAX_NAME,
      { nameLength = nameLength }
    )
  end

  local cursor = 5
  local name = reader:ascii(cursor, nameLength)
  cursor = cursor + nameLength

  local headers = {}
  if hasHeaders then
    for i = 1, cellCount do
      headers[i] = reader:u16le(cursor)
      cursor = cursor + 2
    end
  else
    for i = 1, cellCount do
      headers[i] = defaultMapHeaderId
    end
  end

  local altitudes = {}
  if hasAltitudes then
    for i = 1, cellCount do
      altitudes[i] = reader:u8(cursor)
      cursor = cursor + 1
    end
  else
    for i = 1, cellCount do
      altitudes[i] = 0
    end
  end

  local modelIds = {}
  for i = 1, cellCount do
    modelIds[i] = reader:u16le(cursor)
    cursor = cursor + 2
  end
  -- cursor is now the end of the required bytes; trailing NARC alignment padding
  -- is tolerated, but a short member has already raised READ_OUT_OF_BOUNDS above.

  return setmetatable({
    width = width,
    height = height,
    name = name,
    hasHeaders = hasHeaders,
    hasAltitudes = hasAltitudes,
    headers = headers,
    altitudes = altitudes,
    modelIds = modelIds,
  }, MapMatrix)
end

function MapMatrix.decode(data, defaultMapHeaderId)
  assert(type(data) == "string", "MapMatrix.decode requires a string")
  local ok, result = pcall(parse, data, defaultMapHeaderId)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

-- Zero-based cell index for (x, y), validating both against the dimensions.
-- Cell indices are finite integers: a fractional index would otherwise key
-- the value tables with a fraction and silently return nil.
function MapMatrix:index(x, y)
  if not finiteInteger(x) or not finiteInteger(y) then
    Errors.raise(
      "MAP_MATRIX_COORD_OUT_OF_RANGE",
      "coordinate (" .. tostring(x) .. ", " .. tostring(y) .. ") is not a finite integer cell index",
      { x = x, y = y, width = self.width, height = self.height }
    )
  end
  if x < 0 or y < 0 or x >= self.width or y >= self.height then
    Errors.raise(
      "MAP_MATRIX_COORD_OUT_OF_RANGE",
      "coordinate (" .. tostring(x) .. ", " .. tostring(y) .. ") outside " .. self.width .. "x" .. self.height,
      { x = x, y = y, width = self.width, height = self.height }
    )
  end
  return y * self.width + x
end

function MapMatrix:mapHeaderIdAt(x, y)
  return self.headers[self:index(x, y) + 1]
end
function MapMatrix:altitudeAt(x, y)
  return self.altitudes[self:index(x, y) + 1]
end
function MapMatrix:modelIdAt(x, y)
  return self.modelIds[self:index(x, y) + 1]
end

-- One matrix cell spans a fixed square of field tiles; the model-grid entry is
-- the land-data member for that cell.
local TILES_PER_CELL = 32

-- Bundle the three per-cell values at (x, z). Matrix rows run along z.
function MapMatrix:cell(x, z)
  local i = self:index(x, z)
  return {
    mapHeaderId = self.headers[i + 1],
    altitude = self.altitudes[i + 1],
    landDataMemberId = self.modelIds[i + 1],
  }
end

-- Global tile origin of cell (x, z): the top-left field tile it owns.
function MapMatrix:worldOrigin(x, z)
  self:index(x, z) -- bounds-check
  return x * TILES_PER_CELL, z * TILES_PER_CELL
end

-- Every cell whose map-header id equals mapId, in row-major (index) order.
function MapMatrix:findCellsByMapHeaderId(mapId)
  local out = {}
  for z = 0, self.height - 1 do
    for x = 0, self.width - 1 do
      local i = z * self.width + x
      if self.headers[i + 1] == mapId then
        out[#out + 1] = { x = x, z = z, index = i }
      end
    end
  end
  return out
end

return MapMatrix
