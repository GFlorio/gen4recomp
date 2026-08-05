-- Resolves a semantic map (id or MAP_* symbol) to a pure ResolvedMap data
-- object: the matrix cell, land-data member, area-data member, and global tile
-- origin. It is the single place that turns "which map" into "which ROM
-- members", derived from the decoded matrix rather than hard-coded per target.
-- Pure domain module: it depends only on a RomFs-shaped object exposing
-- openNarc("map_matrices"):readMember(id). No NARC handle leaks into the result.

local Errors = require("libs.rom.src.Errors")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local MapMatrix = require("romdump.src.digest.MapMatrix")

local MapResolver = {}

local function must(value, err)
  if value == nil then error(err) end
  return value
end

-- Apply the section 9.2 cell-selection rules. Returns the chosen
-- { x, z, index } or raises a structured error.
local function chooseCell(matrix, record, cells)
  if #cells == 1 then
    return cells[1]
  end

  local expected = record.expectedMatrixCell
  if expected then
    for _, c in ipairs(cells) do
      if c.x == expected.x and c.z == expected.z then return c end
    end
    Errors.raise("MAP_RESOLVE_EXPECTED_CELL_MISMATCH",
      "expected matrix cell not among map-header matches",
      { mapId = record.id, expected = expected, matchCount = #cells })
  end

  if not matrix.hasHeaders and matrix.width == 1 and matrix.height == 1 then
    return { x = 0, z = 0, index = 0 }
  end

  if #cells == 0 then
    Errors.raise("MAP_RESOLVE_NO_MATCHING_CELL",
      "no matrix cell references map-header id " .. record.id, { mapId = record.id })
  end
  Errors.raise("AMBIGUOUS_MAP_MATRIX_CELL",
    #cells .. " matrix cells reference map-header id " .. record.id
      .. " and the catalog has no expectedMatrixCell",
    { mapId = record.id, matchCount = #cells })
end

local function resolve(romFs, idOrSymbol)
  local record = MapCatalog.require(idOrSymbol)

  local narc = must(romFs:openNarc("map_matrices"))
  local bytes = must(narc:readMember(record.matrixMemberId))
  local matrix = must(MapMatrix.decode(bytes, record.id))

  local cells = matrix:findCellsByMapHeaderId(record.id)
  local chosen = chooseCell(matrix, record, cells)
  local cell = matrix:cell(chosen.x, chosen.z)

  -- Section 9.2 step 10: compare the resolved cell and land member against the
  -- checked-in catalog expectations before trusting them.
  local expected = record.expectedMatrixCell
  if expected and (chosen.x ~= expected.x or chosen.z ~= expected.z) then
    Errors.raise("MAP_RESOLVE_EXPECTED_CELL_MISMATCH",
      "resolved cell does not match catalog expectedMatrixCell",
      { mapId = record.id, expected = expected, resolved = { x = chosen.x, z = chosen.z } })
  end
  if record.expectedLandDataMemberId ~= nil
      and cell.landDataMemberId ~= record.expectedLandDataMemberId then
    Errors.raise("MAP_RESOLVE_LAND_MEMBER_MISMATCH",
      "resolved land-data member does not match catalog expectation",
      { mapId = record.id, expected = record.expectedLandDataMemberId,
        resolved = cell.landDataMemberId })
  end

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
