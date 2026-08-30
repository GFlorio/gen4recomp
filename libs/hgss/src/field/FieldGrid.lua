-- Maps permission-grid tile coordinates to the renderer's world space. A land
-- cell is 32x32 field tiles and the compiled map model is placed with its local
-- origin at the cell centre (verified against real dumps: New Bark's outdoor map
-- model spans model X/Z ~[-16, 16], and Elm's interior room sits in the same
-- centred frame), so tile (0,0)'s centre is at world (-15.5, -15.5) and tile
-- (31,31)'s at (15.5, 15.5). One world unit per tile, +X east / +Z south to
-- match MapUnits. This centring is the project-owned placement convention the
-- camera profiles share: if a later map proves a different placement the
-- constant lives here alone.
-- Pure domain module (no love).

local FieldGrid = {}

FieldGrid.CELL_TILES = 32
local HALF = FieldGrid.CELL_TILES / 2

-- World XZ of the centre of local tile (localX, localZ). Y is a render concern
-- (flat, BDHC-deferred) and is not decided here.
function FieldGrid.tileCenterToWorld(localX, localZ)
  return localX + 0.5 - HALF, localZ + 0.5 - HALF
end

return FieldGrid
