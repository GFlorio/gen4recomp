-- Defines the strict generated physical-cell cache. Runtime consumers resolve
-- matrix coordinates from this index and never need ROM or logical-map scenes.

local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local Contract = require("libs.assets.src.DerivedAssetContract")
local Validate = require("libs.assets.src.Validate")

local FieldCellCache = {}
FieldCellCache.FORMAT = Contract.fieldCells.cacheFormat
FieldCellCache.INDEX_SCHEMA = Contract.fieldCells.indexSchema
FieldCellCache.CELL_SCHEMA = Contract.fieldCells.cellSchema

local ROOT = "data/generated/field/cells"

function FieldCellCache.dir()
  return ROOT
end
function FieldCellCache.indexPath()
  return ROOT .. "/index.lua"
end
function FieldCellCache.markerPath()
  return ROOT .. "/complete"
end
function FieldCellCache.cellDir(matrixMemberId, index)
  return string.format("%s/%d/%d", ROOT, matrixMemberId, index)
end
function FieldCellCache.cellPath(matrixMemberId, index)
  return FieldCellCache.cellDir(matrixMemberId, index) .. "/cell.lua"
end
function FieldCellCache.collisionPath(matrixMemberId, index)
  return FieldCellCache.cellDir(matrixMemberId, index) .. "/collision.g4collision"
end
function FieldCellCache.terrainPath(matrixMemberId, index)
  return FieldCellCache.cellDir(matrixMemberId, index) .. "/terrain.lua"
end
function FieldCellCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", FieldCellCache.FORMAT, romSha1, dependencyHash)
end

local function validId(value)
  return Validate.isNonNegativeInteger(value)
end

local function validCell(record, matrix)
  return type(record) == "table"
    and validId(record.index)
    and validId(record.x)
    and validId(record.z)
    and record.x < matrix.width
    and record.z < matrix.height
    and validId(record.mapHeaderId)
    and validId(record.altitude)
    and validId(record.landDataMemberId)
    and validId(record.areaDataMemberId)
    and record.file == FieldCellCache.cellPath(matrix.matrixMemberId, record.index)
end

local function validateIndex(index)
  if type(index) ~= "table" or index.schema ~= FieldCellCache.INDEX_SCHEMA or not Validate.isArray(index.matrices) then
    return false
  end
  local seenMatrices = {}
  for _, matrix in ipairs(index.matrices) do
    if
      type(matrix) ~= "table"
      or not validId(matrix.matrixMemberId)
      or not validId(matrix.width)
      or not validId(matrix.height)
      or matrix.width < 1
      or matrix.height < 1
      or not Validate.isArray(matrix.cells)
      or seenMatrices[matrix.matrixMemberId]
    then
      return false
    end
    seenMatrices[matrix.matrixMemberId] = true
    local seenCells = {}
    local seenCoordinates = {}
    for _, cell in ipairs(matrix.cells) do
      local coordinateKey = type(cell) == "table" and string.format("%s:%s", cell.x, cell.z) or "invalid"
      if
        not validCell(cell, matrix)
        or cell.matrixMemberId ~= matrix.matrixMemberId
        or seenCells[cell.index]
        or seenCoordinates[coordinateKey]
      then
        return false
      end
      seenCells[cell.index] = true
      seenCoordinates[coordinateKey] = true
    end
  end
  return true
end

function FieldCellCache.validateCell(cacheFs, cell)
  if type(cell) ~= "table" or cell.schema ~= FieldCellCache.CELL_SCHEMA then
    return false
  end
  for _, key in ipairs({
    "matrixMemberId",
    "index",
    "x",
    "z",
    "mapHeaderId",
    "altitude",
    "landDataMemberId",
    "areaDataMemberId",
  }) do
    if not validId(cell[key]) then
      return false
    end
  end
  if
    type(cell.collision) ~= "table"
    or type(cell.collision.file) ~= "string"
    or type(cell.terrain) ~= "table"
    or type(cell.terrain.file) ~= "string"
    or not Validate.isArray(cell.batches)
    or not Validate.isArray(cell.materials)
    or not Validate.isArray(cell.buildingInstances)
  then
    return false
  end
  if
    cell.collision.width ~= 32
    or cell.collision.height ~= 32
    or not cacheFs:exists(cell.collision.file, "file")
    or not cacheFs:exists(cell.terrain.file, "file")
  then
    return false
  end
  local bytes = cacheFs:read(cell.collision.file)
  local collision = bytes and CollisionGridAsset.decode(bytes)
  return collision ~= nil and collision.width == 32 and collision.height == 32
end

function FieldCellCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldCellCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(FieldCellCache.indexPath())
  if not validateIndex(index) then
    return false
  end
  for _, matrix in ipairs(index.matrices) do
    for _, entry in ipairs(matrix.cells) do
      local cell = cacheFs:loadLua(entry.file)
      if not FieldCellCache.validateCell(cacheFs, cell) then
        return false
      end
    end
  end
  return true
end

function FieldCellCache.loadIndex(cacheFs)
  local index = cacheFs:loadLua(FieldCellCache.indexPath())
  assert(validateIndex(index), "field cell index is malformed")
  return index
end

function FieldCellCache.find(index, matrixMemberId, x, z)
  for _, matrix in ipairs(index.matrices) do
    if matrix.matrixMemberId == matrixMemberId then
      for _, cell in ipairs(matrix.cells) do
        if cell.x == x and cell.z == z then
          return cell
        end
      end
      return nil
    end
  end
  return nil
end

return FieldCellCache
