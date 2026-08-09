-- Coordinate calibration between Nitro model space and the runtime field grid.
-- GxDisplayList emits map-model vertices in pre-posScale local space; the model
-- header's posScale (an fx32 factor, e.g. 64 for Elm's Lab) is what the SBC
-- POSSCALE op folds back in to reach model space. One 32-tile map chunk spans
-- ~512 model units, so 16 model units == 1 field tile, and the runtime uses one
-- world unit per tile. The runtime axes (+X east, +Y up, +Z south) use the same
-- handedness as Nitro here, so this is a pure scale with no winding flip. Pure
-- domain module. The axis convention is provisional and centralized here so a
-- later render calibration changes exactly one place.

local Errors = require("libs.rom.src.Errors")

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

-- A column-major position matrix rescaled to act on already-tiled vertices:
-- only the translation column is divided by the tile size. Since the tile
-- conversion is a uniform scale, M applied before toTiles and this matrix
-- applied after it land a vertex in the same place -- which is what lets a
-- billboard's base transform ride alongside toTiles-converted geometry.
function MapUnits.matrixToTiles(m)
  local out = {}
  for i = 1, 12 do
    out[i] = m[i]
  end
  out[13], out[14], out[15] = MapUnits.toTiles(m[13], m[14], m[15])
  out[16] = m[16]
  return out
end

-- X and Z extents of a { min = {x,y,z}, max = {x,y,z} } box, in runtime tiles.
function MapUnits.extentTiles(bounds, posScale)
  local f = posScale / MapUnits.MODEL_UNITS_PER_TILE
  return (bounds.max[1] - bounds.min[1]) * f, (bounds.max[3] - bounds.min[3]) * f
end

local function isFinitePositive(n)
  return n > 0 and n < math.huge
end

-- Sanity-check that scale conversion produces usable planar bounds. Land
-- models may legitimately span several 32-tile matrix cells, so their size is
-- not itself a calibration invariant.
function MapUnits.assertMapCalibration(bounds, posScale, context)
  local ex, ez = MapUnits.extentTiles(bounds, posScale)
  if not (isFinitePositive(posScale) and isFinitePositive(ex) and isFinitePositive(ez)) then
    Errors.raise(
      "MAP_COMPILE_CALIBRATION",
      string.format("map model extents must be finite and positive (x=%.2f, z=%.2f)", ex, ez),
      { context = context, exTiles = ex, ezTiles = ez, posScale = posScale }
    )
  end
  return ex, ez
end

return MapUnits
