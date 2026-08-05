-- Replays a decoded NSBMD model's SBC draw stream into normalized triangle-list
-- batches, one per draw (a shape bound to a material and node). It evaluates the
-- static SBC matrix state (node matrices + POSSCALE) once, then re-decodes each
-- shape display list with that matrix and restore-stack snapshot so the DS
-- geometry-engine color/normal state seeded from the active material reaches the
-- vertices. Every vertex carries a resolved color source (literal, normal-lit, or
-- field diffuse) and has already been transformed to model units, so the only
-- remaining conversion is the fixed tile-size divisor (MapUnits.toTiles). UVs
-- stay in texel units for the caller to normalize. The material's resolved
-- polygon-attr word rides on each batch. Pure domain module; the compiler
-- boundary at which DS geometry stops.

local Errors = require("libs.rom.src.Errors")
local MapUnits = require("libs.assets.src.MapUnits")
local GxDisplayList = require("libs.assets.src.nitro.GxDisplayList")
local DsMaterial = require("libs.assets.src.nitro.DsMaterial")
local DsPolygonAttr = require("libs.assets.src.nitro.DsPolygonAttr")
local FixedPoint = require("libs.math.src.FixedPoint")
local NsbmdStaticTransforms = require("libs.assets.src.NsbmdStaticTransforms")

local MeshCompiler = {}

local COLOR_SOURCE = GxDisplayList.COLOR_SOURCE

-- In-display-list opcodes the field compiler does not support (the target
-- inventory has none; a future model that uses one fails loudly here).
local UNSUPPORTED_DL_OPCODES = {
  [0x30] = { code = "MAP_COMPILE_LOCAL_LIGHT_OVERRIDE_UNSUPPORTED", name = "DIF_AMB" },
  [0x31] = { code = "MAP_COMPILE_LOCAL_LIGHT_OVERRIDE_UNSUPPORTED", name = "SPE_EMI" },
  [0x32] = { code = "MAP_COMPILE_LOCAL_LIGHT_OVERRIDE_UNSUPPORTED", name = "LIGHT_VECTOR" },
  [0x33] = { code = "MAP_COMPILE_LOCAL_LIGHT_OVERRIDE_UNSUPPORTED", name = "LIGHT_COLOR" },
  [0x34] = { code = "MAP_COMPILE_SHININESS_UNSUPPORTED", name = "SHININESS" },
}

-- Resolve a raw material to its effective field state plus the geometry-engine
-- color seed a shape inherits when this material is (re)applied. Every field
-- material sets vertex color, so the seed always resolves a color source.
local function materialState(rawMaterial)
  local resolved = DsMaterial.resolve(rawMaterial, DsMaterial.HGSS_FIELD_DEFAULTS,
    DsMaterial.applyFieldPolicy(rawMaterial))
  local seed
  if rawMaterial.setVertexColor then
    local diffuse = resolved.colors.diffuse
    local r, g, b = FixedPoint.rgb555(diffuse.rgb555)
    seed = {
      color = { r, g, b },
      colorSource = diffuse.source == "field" and COLOR_SOURCE.FIELD_DIFFUSE or COLOR_SOURCE.LITERAL,
    }
  else
    -- Not a set-vertex-color material: the display list must set COLOR/NORMAL
    -- before any vertex, else the requireColorSource guard raises.
    seed = { colorSource = nil }
  end
  return { polygonAttrRaw = resolved.polyAttr, seed = seed }
end

-- Reject any in-DL command the compiler cannot honor, and any in-DL POLYGON_ATTR
-- override (the material owns polygon state for field models).
local function assertSupportedShape(geom, context)
  for opcode, info in pairs(UNSUPPORTED_DL_OPCODES) do
    if geom.opcodeCounts[opcode] then
      Errors.raise(info.code,
        "shape display list issues unsupported " .. info.name .. " command", context)
    end
  end
  if #geom.polygonAttrs > 0 then
    Errors.raise("GX_STATE_CHANGE_INSIDE_PRIMITIVE",
      "shape display list overrides POLYGON_ATTR; field polygon state must come from the material", context)
  end
end

-- model: a Nsbmd model (info.posScale/invPosScale, shapes[i].{index,displayListBytes},
-- materials, sbc.commands, nodes). Returns a list of batches, each:
-- { nodeIndex, materialIndex, shapeIndex, submissionIndex, polygonAttrRaw,
--   vertices = { {x,y,z,u,v,nx,ny,nz,r,g,b,a,colorSource}, ... }, indices }.
function MeshCompiler.compile(model)
  local shapeByIndex = {}
  for _, shp in ipairs(model.shapes) do shapeByIndex[shp.index] = shp end

  local stateByMaterial = {}
  for _, mat in ipairs(model.materials) do stateByMaterial[mat.index] = materialState(mat) end

  local draws = NsbmdStaticTransforms.evaluate(model)

  local batches = {}
  local carriedState -- geometry-engine color state carried across shapes
  for submissionIndex, draw in ipairs(draws) do
    local shp = shapeByIndex[draw.shapeIndex]
    if not shp then
      Errors.raise("MAP_COMPILE_MISSING_SHAPE",
        "SBC draw references shape index " .. tostring(draw.shapeIndex) .. " not in the model",
        { shapeIndex = draw.shapeIndex, materialIndex = draw.materialIndex })
    end
    local matState = stateByMaterial[draw.materialIndex]
    assert(matState, "SBC draw references material " .. tostring(draw.materialIndex) .. " not in the model")

    -- Seed from the material when it was reapplied at this draw, else carry the
    -- previous shape's final color/normal state.
    local initialState = draw.materialReapplied and matState.seed or carriedState or matState.seed

    local context = { model = model.name, shape = shp.name, material = draw.materialIndex }
    local geom, err = GxDisplayList.decode(shp.displayListBytes,
      { initialState = initialState, matrix = draw.matrix, restoreStack = draw.restoreStack,
        requireColorSource = true, context = context })
    if not geom then error(err) end
    assertSupportedShape(geom, context)
    carriedState = geom.finalState

    local vertices = {}
    for _, v in ipairs(geom.vertices) do
      local x, y, z = MapUnits.toTiles(v.x, v.y, v.z)
      vertices[#vertices + 1] = {
        x = x, y = y, z = z,
        u = v.u, v = v.v,
        nx = v.nx, ny = v.ny, nz = v.nz,
        r = v.r, g = v.g, b = v.b, a = v.a or 255,
        colorSource = v.colorSource,
      }
    end

    local indices = {}
    for i = 1, #geom.indices do indices[i] = geom.indices[i] end

    local poly = DsPolygonAttr.decode(matState.polygonAttrRaw)
    if poly.polygonMode ~= "modulation" and poly.polygonMode ~= "decal" then
      Errors.raise("MAP_COMPILE_UNSUPPORTED_POLYGON_MODE",
        "polygon mode " .. poly.polygonMode .. " is not supported",
        { model = model.name, material = draw.materialIndex, shape = shp.name,
          polygonMode = poly.polygonMode, polygonAttrRaw = matState.polygonAttrRaw })
    end

    batches[#batches + 1] = {
      nodeIndex = draw.nodeIndex,
      materialIndex = draw.materialIndex,
      shapeIndex = draw.shapeIndex,
      submissionIndex = submissionIndex,
      polygonAttrRaw = matState.polygonAttrRaw,
      vertices = vertices,
      indices = indices,
    }
  end
  return batches
end

return MeshCompiler
