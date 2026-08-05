-- Pure plan of the presentation-only ring of the eight matrix cells surrounding
-- a central map cell. Given a decoded MapMatrix, the centre cell, and a
-- header->area resolver, plan() returns the neighbour cells to draw -- each with
-- its exact 32-tile world offset, decoded map-header id, land-data member, and
-- resolved area member -- plus the deduplicated set of land members so the
-- loader compiles/instances each unique chunk once. Out-of-bounds cells are
-- skipped without wrapping; cells whose header has no checked-in area mapping are
-- skipped too. Neighbours are additive: with the feature disabled nothing is
-- planned and the central scene is untouched. Pure domain module (no love, no
-- libs/engine).

local NeighborPlan = {}

-- The eight surrounding cells in a deterministic row-major order so the planned
-- list (and every downstream draw list) is stable.
local OFFSETS = {
  { dx = -1, dz = -1 }, { dx = 0, dz = -1 }, { dx = 1, dz = -1 },
  { dx = -1, dz = 0 }, { dx = 1, dz = 0 },
  { dx = -1, dz = 1 }, { dx = 0, dz = 1 }, { dx = 1, dz = 1 },
}

local TILES_PER_CELL = 32  -- DS matrix cell is 32x32 tiles (FieldGrid.CELL_TILES); inlined so this pure-domain module stays free of the libs/engine dependency

local function inBounds(matrix, x, z)
  return x >= 0 and z >= 0 and x < matrix.width and z < matrix.height
end

-- Pure plan of the neighbour ring around cell (cx, cz). `areaForHeader` maps a
-- decoded map-header id to an area-data member id (or nil to skip the cell).
function NeighborPlan.plan(matrix, cx, cz, areaForHeader)
  local cells = {}
  local uniqueSet = {}
  for _, off in ipairs(OFFSETS) do
    local x, z = cx + off.dx, cz + off.dz
    if inBounds(matrix, x, z) then
      local cell = matrix:cell(x, z)
      local area = areaForHeader(cell.mapHeaderId)
      if area ~= nil and cell.landDataMemberId ~= 0xFFFF then
        cells[#cells + 1] = {
          x = x,
          z = z,
          dx = off.dx,
          dz = off.dz,
          offsetTilesX = off.dx * TILES_PER_CELL,
          offsetTilesZ = off.dz * TILES_PER_CELL,
          mapHeaderId = cell.mapHeaderId,
          landDataMemberId = cell.landDataMemberId,
          areaDataMemberId = area,
        }
        uniqueSet[cell.landDataMemberId] = true
      end
    end
  end

  local uniqueLandMembers = {}
  for member in pairs(uniqueSet) do uniqueLandMembers[#uniqueLandMembers + 1] = member end
  table.sort(uniqueLandMembers)

  return { cells = cells, uniqueLandMembers = uniqueLandMembers }
end

return NeighborPlan
