-- Coordinate calibration between Nitro model space and the runtime field grid.
-- GxDisplayList emits map-model vertices in pre-posScale local space; the model
-- header's posScale (an fx32 factor, e.g. 64 for Elm's Lab) is what the SBC
-- POSSCALE op folds back in to reach model space. One 32-tile map chunk spans
-- ~512 model units, so 16 model units == 1 field tile, and the runtime uses one
-- world unit per tile. The runtime axes (+X east, +Y up, +Z south) use the same
-- handedness as Nitro here, so this is a pure scale with no winding flip. Pure
-- domain module. The axis convention is provisional and centralized here so a
-- later render calibration changes exactly one place.

local Errors = require("src.import.Errors")

local MapUnits = {}

MapUnits.MODEL_UNITS_PER_TILE = 16

-- A model coordinate, folded through posScale and tile size, in runtime tiles.
function MapUnits.toRuntime(x, y, z, posScale)
  local f = posScale / MapUnits.MODEL_UNITS_PER_TILE
  return x * f, y * f, z * f
end

-- A position-matrix-transformed vertex, already in model units, converted to
-- runtime tiles. This is the compile path after NsbmdStaticTransforms applies
-- the SBC POSSCALE / node matrix state.
function MapUnits.toTiles(x, y, z)
  local f = 1 / MapUnits.MODEL_UNITS_PER_TILE
  return x * f, y * f, z * f
end

-- X and Z extents of a { min = {x,y,z}, max = {x,y,z} } box, in runtime tiles.
function MapUnits.extentTiles(bounds, posScale)
  local f = posScale / MapUnits.MODEL_UNITS_PER_TILE
  return (bounds.max[1] - bounds.min[1]) * f, (bounds.max[3] - bounds.min[3]) * f
end

-- Sanity-check a map model spans a plausible fraction of a 32-tile cell. A cell
-- is 32 tiles; allow slack for walls/overhang. A dominant extent that is
-- non-positive or far past a cell signals a broken posScale/axis assumption.
function MapUnits.assertMapCalibration(bounds, posScale, context)
  local ex, ez = MapUnits.extentTiles(bounds, posScale)
  local dominant = math.max(ex, ez)
  if dominant <= 0 or dominant > 34 then
    Errors.raise("MAP_COMPILE_CALIBRATION",
      string.format("map model dominant extent %.2f tiles is outside (0, 34]", dominant),
      { context = context, exTiles = ex, ezTiles = ez, posScale = posScale })
  end
  return ex, ez
end

return MapUnits
