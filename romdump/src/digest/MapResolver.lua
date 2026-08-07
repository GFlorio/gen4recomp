-- Resolves a semantic map (id or MAP_* symbol) to a pure ResolvedMap data
-- object: the matrix cell, land-data member, area-data member, and global tile
-- origin. It is the single place that turns "which map" into "which ROM
-- members", derived from the decoded matrix rather than hard-coded per target.
-- Pure domain module: it depends only on a RomFs-shaped object exposing
-- openNarc("map_matrices"):readMember(id). No NARC handle leaks into the result.

local Errors = require("libs.rom.src.Errors")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local MapCellSelector = require("romdump.src.digest.MapCellSelector")
local MapMatrix = require("libs.assets.src.MapMatrix")

local MapResolver = {}

local function must(value, err)
  if value == nil then error(err) end
  return value
end

local function resolve(romFs, idOrSymbol)
  local record = MapCatalog.require(idOrSymbol)

  local narc = must(romFs:openNarc("map_matrices"))
  local bytes = must(narc:readMember(record.matrixMemberId))
  local matrix = must(MapMatrix.decode(bytes, record.id))

  local chosen, reason = MapCellSelector.choose(matrix, record)
  if not chosen then
    if reason == "default_header_filler" then
      Errors.raise("MAP_RESOLVE_NOT_RENDERABLE", "map is excluded from rendering",
        { mapId = record.id })
    end
    Errors.raise("MAP_RESOLVE_NO_MATCHING_CELL",
      "no matrix cell references map-header id " .. record.id, { mapId = record.id })
  end
  -- LuaLS cannot see through Errors.raise; the assert narrows the cell.
  chosen = assert(chosen)
  local cell = matrix:cell(chosen.x, chosen.z)

  local worldOriginX, worldOriginZ = matrix:worldOrigin(chosen.x, chosen.z)

  return {
    map = record,
    matrix = matrix,
    matrixMemberId = record.matrixMemberId,
    matrixX = chosen.x,
    matrixZ = chosen.z,
    matrixIndex = chosen.index,
    matrixAltitude = cell.altitude,
    landDataMemberId = cell.landDataMemberId,
    areaDataMemberId = record.areaDataMemberId,
    worldOriginX = worldOriginX,
    worldOriginZ = worldOriginZ,
    source = {
      matrixNarc = "map_matrices",
      landDataNarc = "land_data",
      areaDataNarc = "area_data",
    },
  }
end

function MapResolver.resolve(romFs, idOrSymbol)
  assert(romFs and romFs.openNarc, "resolve requires a RomFs-shaped object")
  local ok, result = pcall(resolve, romFs, idOrSymbol)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return MapResolver
