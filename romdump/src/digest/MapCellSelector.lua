-- Selects the representative matrix cell used to compile a map scene. Multi-
-- cell maps use the cell nearest their matching-region centroid, maximizing the
-- useful coverage of the neighboring field region without hand-tuning.

local MapCellSelector = {}

local function centroidCell(cells)
  local sumX, sumZ = 0, 0
  for _, cell in ipairs(cells) do
    sumX = sumX + cell.x
    sumZ = sumZ + cell.z
  end
  local centerX, centerZ = sumX / #cells, sumZ / #cells
  local chosen, chosenDistance
  for _, cell in ipairs(cells) do
    local dx, dz = cell.x - centerX, cell.z - centerZ
    local distance = dx * dx + dz * dz
    if not chosen or distance < chosenDistance then
      chosen, chosenDistance = cell, distance
    end
  end
  return chosen
end

function MapCellSelector.choose(matrix, record)
  local cells = matrix:findCellsByMapHeaderId(record.id)
  if record.id == 0 then return nil, "default_header_filler", #cells end
  if #cells == 1 then return cells[1], "unique_cell", 1 end
  if #cells == 0 then return nil, "no_matching_cell", 0 end
  return centroidCell(cells), "matching_region_centroid", #cells
end

return MapCellSelector
