-- Turns a decoded NSBMD model's SBC draw stream into normalized triangle-list
-- batches, one per draw (a shape bound to a material and node). Vertex positions
-- are folded through the model's posScale and the map-unit/tile calibration
-- (MapUnits); UV, normal, and color attributes -- already snapshotted per vertex
-- by GxDisplayList -- are copied through. Indices are copied verbatim: the
-- runtime axis mapping preserves handedness, so no winding flip is needed. Pure
-- domain module; the compiler boundary at which DS geometry stops.

local Errors = require("src.import.Errors")
local MapUnits = require("src.import.MapUnits")

local MeshCompiler = {}

-- model: a Nsbmd model (info.posScale, shapes[i].{index,geometry}, sbc.draws).
-- Returns { { nodeIndex, materialIndex, shapeIndex, vertices, indices }, ... }.
function MeshCompiler.compile(model)
  local posScale = model.info.posScale
  assert(type(posScale) == "number", "model.info.posScale must be a number")

  local shapeByIndex = {}
  for _, shp in ipairs(model.shapes) do shapeByIndex[shp.index] = shp end

  local batches = {}
  for _, draw in ipairs(model.sbc.draws) do
    local shp = shapeByIndex[draw.shapeIndex]
    if not shp then
      Errors.raise("MAP_COMPILE_MISSING_SHAPE",
        "SBC draw references shape index " .. tostring(draw.shapeIndex) .. " not in the model",
        { shapeIndex = draw.shapeIndex, materialIndex = draw.materialIndex })
    end
    local geom = shp.geometry

    local vertices = {}
    for _, v in ipairs(geom.vertices) do
      local x, y, z = MapUnits.toRuntime(v.x, v.y, v.z, posScale)
      vertices[#vertices + 1] = {
        x = x, y = y, z = z,
        u = v.u, v = v.v,
        nx = v.nx, ny = v.ny, nz = v.nz,
        r = v.r, g = v.g, b = v.b, a = v.a or 255,
      }
    end

    local indices = {}
    for i = 1, #geom.indices do indices[i] = geom.indices[i] end

    batches[#batches + 1] = {
      nodeIndex = draw.nodeIndex,
      materialIndex = draw.materialIndex,
      shapeIndex = draw.shapeIndex,
      vertices = vertices,
      indices = indices,
    }
  end
  return batches
end

return MeshCompiler
