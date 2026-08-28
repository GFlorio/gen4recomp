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
--
-- compileDynamic is the animation-capable counterpart: the SBC draw matrix is
-- left unbaked and each shape decodes into transform segments whose sources
-- the runtime pose resolves per frame (see GxDisplayList options.dynamic).

local Errors = require("libs.errors.src.Errors")
local MapUnits = require("romdump.src.digest.MapUnits")
local GxDisplayList = require("romdump.src.digest.nitro.GxDisplayList")
local DsMaterial = require("romdump.src.digest.nitro.DsMaterial")
local DsPolygonAttr = require("romdump.src.digest.nitro.DsPolygonAttr")
local FixedPoint = require("libs.math.src.FixedPoint")
local Matrix4 = require("libs.math.src.Matrix4")
local PoseContract = require("libs.assets.src.PoseContract")
local NsbmdStaticTransforms = require("romdump.src.digest.NsbmdStaticTransforms")

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
  local resolved =
    DsMaterial.resolve(rawMaterial, DsMaterial.HGSS_FIELD_DEFAULTS, DsMaterial.applyFieldPolicy(rawMaterial))
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
      Errors.raise(info.code, "shape display list issues unsupported " .. info.name .. " command", context)
    end
  end
  if #geom.polygonAttrs > 0 then
    Errors.raise(
      "GX_STATE_CHANGE_INSIDE_PRIMITIVE",
      "shape display list overrides POLYGON_ATTR; field polygon state must come from the material",
      context
    )
  end
end

-- A billboard's matrix is rebuilt from the camera each frame, so its base
-- transform applies to the whole shape at once. A display list that restores a
-- matrix mid-stream would need a different matrix per primitive, which that
-- contract cannot express; no billboard shape in the target world does.
local MTX_RESTORE = 0x14

local function assertWholeShapeBillboard(geom, context)
  if geom.opcodeCounts[MTX_RESTORE] then
    Errors.raise(
      "MAP_COMPILE_BILLBOARD_MATRIX_RESTORE_UNSUPPORTED",
      "a billboard shape's display list restores a matrix, so one billboard matrix cannot cover it",
      context
    )
  end
end

-- model: a Nsbmd model (info.posScale/invPosScale, shapes[i].{index,displayListBytes},
-- materials, sbc.commands, nodes). Returns a list of batches, each:
-- { nodeIndex, materialIndex, shapeIndex, polygonAttrRaw,
--   transformMode, baseTransform, vertices = { {x,y,z,u,v,nx,ny,nz,r,g,b,a,
--   colorSource}, ... }, indices }. The list order is the SBC submission
-- order; the render queue derives submission order from that position, so
-- no batch carries an index of its own. Billboard
-- batches carry `baseTransform` (tile-space translation, see
-- MapUnits.matrixToTiles); static ones do not.
---@class CompiledVertex
---@field x number
---@field y number
---@field z number
---@field u number
---@field v number
---@field nx number
---@field ny number
---@field nz number
---@field r number
---@field g number
---@field b number
---@field a number
---@field colorSource integer

-- A compiled static batch (one per SBC draw): the display-list geometry in
-- tile space, as documented on compile().
---@class CompiledBatch
---@field nodeIndex integer
---@field materialIndex integer
---@field shapeIndex integer
---@field polygonAttrRaw integer
---@field transformMode TransformMode
---@field baseTransform number[]|nil
---@field vertices CompiledVertex[]
---@field indices integer[]

-- Decode every draw of `draws` into the per-draw inputs both compile paths
-- consume: the shape, its decoded geometry, and the resolved material state.
-- Owns the shared prologue (shape/material lookup, geometry-engine color
-- carry, unsupported-opcode and billboard-matrix guards). `dynamic` selects
-- the transform-preserving decode (pre-draw-space segments) over the static
-- bake of the draw matrix.
---@param model table
---@param draws table[] SBC draw submissions (the NsbmdSbcEvaluator.evaluate shape)
---@param dynamic boolean
---@return { draw: table, shape: table, matState: { polygonAttrRaw: integer, seed: table|nil }, geom: table }[]
local function decodeDraws(model, draws, dynamic)
  local shapeByIndex = {}
  for _, shp in ipairs(model.shapes) do
    shapeByIndex[shp.index] = shp
  end

  local stateByMaterial = {}
  for _, mat in ipairs(model.materials) do
    stateByMaterial[mat.index] = materialState(mat)
  end

  local decoded = {}
  local carriedState -- geometry-engine color state carried across shapes
  for _, draw in ipairs(draws) do
    local shp = shapeByIndex[draw.shapeIndex]
    if not shp then
      Errors.raise(
        "MAP_COMPILE_MISSING_SHAPE",
        "SBC draw references shape index " .. tostring(draw.shapeIndex) .. " not in the model",
        { shapeIndex = draw.shapeIndex, materialIndex = draw.materialIndex }
      )
    end
    local matState = stateByMaterial[draw.materialIndex]
    assert(matState, "SBC draw references material " .. tostring(draw.materialIndex) .. " not in the model")

    -- Seed from the material when it was reapplied at this draw, else carry the
    -- previous shape's final color/normal state.
    local initialState = carriedState or matState.seed
    if draw.materialReapplied then
      initialState = matState.seed
    end

    local context = { model = model.name, shape = shp.name, material = draw.materialIndex }
    local options = {
      initialState = initialState,
      requireColorSource = true,
      context = context,
    }
    if dynamic then
      options.dynamic = true
    else
      options.matrix = draw.matrix
      options.restoreStack = draw.restoreStack
    end
    local geom, err = GxDisplayList.decode(shp.displayListBytes, options)
    if not geom then
      error(err)
    end
    assertSupportedShape(geom, context)
    if draw.transformMode == PoseContract.BILLBOARD then
      assertWholeShapeBillboard(geom, context)
    end
    carriedState = geom.finalState

    decoded[#decoded + 1] = { draw = draw, shape = shp, matState = matState, geom = geom }
  end
  return decoded
end

-- Compile the static batches of a decoded model (shapes, display lists,
-- materials, sbc.commands, nodes).
---@param model table
---@return CompiledBatch[]
function MeshCompiler.compile(model)
  local batches = {}
  for _, record in ipairs(decodeDraws(model, NsbmdStaticTransforms.evaluate(model), false)) do
    local draw = record.draw
    local shp = record.shape
    local matState = record.matState
    local geom = record.geom

    local vertices = {}
    for _, v in ipairs(geom.vertices) do
      local x, y, z = MapUnits.toTiles(v.x, v.y, v.z)
      vertices[#vertices + 1] = {
        x = x,
        y = y,
        z = z,
        u = v.u,
        v = v.v,
        nx = v.nx,
        ny = v.ny,
        nz = v.nz,
        r = v.r,
        g = v.g,
        b = v.b,
        a = v.a or 255,
        colorSource = v.colorSource,
      }
    end

    local indices = {}
    for i = 1, #geom.indices do
      indices[i] = geom.indices[i]
    end

    local poly = DsPolygonAttr.decode(matState.polygonAttrRaw)
    if poly.polygonMode ~= "modulation" and poly.polygonMode ~= "decal" then
      Errors.raise("MAP_COMPILE_UNSUPPORTED_POLYGON_MODE", "polygon mode " .. poly.polygonMode .. " is not supported", {
        model = model.name,
        material = draw.materialIndex,
        shape = shp.name,
        polygonMode = poly.polygonMode,
        polygonAttrRaw = matState.polygonAttrRaw,
      })
    end

    batches[#batches + 1] = {
      nodeIndex = draw.nodeIndex,
      materialIndex = draw.materialIndex,
      shapeIndex = draw.shapeIndex,
      polygonAttrRaw = matState.polygonAttrRaw,
      transformMode = draw.transformMode,
      baseTransform = draw.baseTransform and MapUnits.matrixToTiles(draw.baseTransform) or nil,
      vertices = vertices,
      indices = indices,
    }
  end
  return batches
end

-- A dynamic mesh record (one per draw segment): geometry in pre-draw space
-- plus the transform source the runtime resolves at draw time.
---@class DynamicMeshRecord
---@field id string
---@field drawIndex integer
---@field segmentIndex integer
---@field nodeIndex integer
---@field materialIndex integer
---@field transformMode TransformMode
---@field positionSource DrawSource|nil -- nil: fully baked (billboard segments)
---@field polygonAttrRaw integer -- the material's polygon-attr word, the same
--  state the static path rides on each batch: cull mode, polygon mode, id,
--  depth flags, polygon alpha
---@field batch { vertices: CompiledVertex[], indices: integer[] }
---@field straddle { leading: integer, source: DrawSource }|nil -- the segment
--  received `leading` vertices submitted under `source` (the pre-boundary
--  matrix) before its own; absent: the whole segment resolves under
--  positionSource

-- Transform-preserving compile: the same draw replay as
-- compile(), but the SBC draw matrix is NOT baked into the vertices.
-- Each shape's display list decodes in dynamic mode (GxDisplayList
-- options.dynamic) into segments whose vertices carry only the
-- display-list-local matrix ops, and each segment records the source that
-- resolves its transform at draw time:
--
--   positionSource = "draw" | { slot = k }
--
-- The runtime evaluates the model's transform program per frame
-- (NitroPoseBackend) and resolves every mesh's sources against the draw
-- record, so the geometry is compiled once and only the matrices move.
-- Billboard draws record no baseTransform: the matrix BB captured is
-- pose-dependent and comes from the runtime pose state each frame.
-- UVs stay in texel units for the caller to normalize.
-- Returns the dynamic mesh records plus, when any compiled mesh carries a
-- straddling-primitive provenance record (a run split at a mid-run matrix
-- boundary, see GxDisplayList options.dynamic), an array of
-- { shape = <name>, straddling = <count> } for the caller to report --
-- one count per provenance record, so every reported straddle is
-- represented by exactly one record on its mesh. The compiled transform
-- program is returned as the third result so the caller does not compile it
-- a second time for the descriptor it ships.
---@return DynamicMeshRecord[]
---@return { shape: string, straddling: integer }[]? straddlingPrimitives
---@return table program
---@param model table
function MeshCompiler.compileDynamic(model)
  -- The draw set (order, visibility, material carries) is pose-independent:
  -- the bind-pose evaluation yields the same draws the static path compiles.
  -- NsbmdStaticTransforms owns the bind-pose replay and returns the program
  -- it compiled, so the descriptor ships that same single compile.
  local draws, program = NsbmdStaticTransforms.evaluate(model)

  local meshes = {}
  local straddlingByShape = {}
  for drawIndex, record in ipairs(decodeDraws(model, draws, true)) do
    local draw = record.draw
    local shp = record.shape
    local matState = record.matState
    local geom = record.geom
    for segmentIndex, segment in ipairs(geom.segments) do
      -- A segment whose run was split at a matrix boundary can hold a lone
      -- straddling vertex with no indices: nothing to draw.
      if #segment.indices == 0 then
        goto continue
      end
      -- A billboard draw's post-BB matrix (POSSCALE folds, nothing else can
      -- touch the matrix without ending the billboard) is pose-independent,
      -- so it bakes into the vertices exactly like the static path; only the
      -- captured baseTransform remains runtime-resolved.
      local bake = draw.transformMode == PoseContract.BILLBOARD and draw.matrix or nil
      -- The linear part of the bake is a per-segment loop invariant: it feeds
      -- the normal transform of every vertex in the segment, so compute it
      -- once per segment, not once per vertex. It is non-nil exactly when the
      -- bake applies (Matrix4.linear is total).
      local bakeLinear = bake and Matrix4.linear(bake) or nil
      local vertices = {}
      for _, v in ipairs(segment.vertices) do
        local x, y, z = v.x, v.y, v.z
        local nx, ny, nz = v.nx, v.ny, v.nz
        if bake and bakeLinear then
          local ox, oy, oz = x, y, z
          x = bake[1] * ox + bake[5] * oy + bake[9] * oz + bake[13]
          y = bake[2] * ox + bake[6] * oy + bake[10] * oz + bake[14]
          z = bake[3] * ox + bake[7] * oy + bake[11] * oz + bake[15]
          local onx, ony, onz = nx, ny, nz
          nx = bakeLinear[1] * onx + bakeLinear[5] * ony + bakeLinear[9] * onz
          ny = bakeLinear[2] * onx + bakeLinear[6] * ony + bakeLinear[10] * onz
          nz = bakeLinear[3] * onx + bakeLinear[7] * ony + bakeLinear[11] * onz
        end
        x, y, z = MapUnits.toTiles(x, y, z)
        vertices[#vertices + 1] = {
          x = x,
          y = y,
          z = z,
          u = v.u,
          v = v.v,
          nx = nx,
          ny = ny,
          nz = nz,
          r = v.r,
          g = v.g,
          b = v.b,
          a = v.a,
          colorSource = v.colorSource,
        }
      end
      local indices = {}
      for i = 1, #segment.indices do
        indices[i] = segment.indices[i]
      end

      -- Billboard segments are fully baked; other segments defer their
      -- transform to their position source.
      local positionSource
      if draw.transformMode == PoseContract.BILLBOARD then
        positionSource = nil
      else
        positionSource = segment.positionSource
      end
      local mesh = {
        id = string.format("draw%d.seg%d", drawIndex - 1, segmentIndex - 1),
        drawIndex = drawIndex - 1,
        segmentIndex = segmentIndex - 1,
        nodeIndex = draw.nodeIndex,
        materialIndex = draw.materialIndex,
        transformMode = draw.transformMode,
        positionSource = positionSource,
        polygonAttrRaw = matState.polygonAttrRaw,
        batch = { vertices = vertices, indices = indices },
      }
      -- A run split at a mid-run matrix boundary: the first `leading`
      -- vertices of this segment were submitted under the PRE-boundary
      -- source, so the record carries the split for the runtime to bend
      -- per-vertex exactly like the geometry engine (the DS transforms each
      -- vertex under the then-current matrix). The straddle report counts
      -- these compiled records, so every reported straddle is represented
      -- by exactly one provenance record on its mesh.
      if segment.straddle then
        mesh.straddle = segment.straddle
        local rec = straddlingByShape[shp.name]
        if not rec then
          rec = { shape = shp.name, straddling = 0 }
          straddlingByShape[shp.name] = rec
        end
        rec.straddling = rec.straddling + 1
      end
      meshes[#meshes + 1] = mesh
      ::continue::
    end
  end
  if next(straddlingByShape) == nil then
    return meshes, nil, program
  end
  local straddling = {}
  for _, rec in pairs(straddlingByShape) do
    straddling[#straddling + 1] = rec
  end
  table.sort(straddling, function(a, b)
    return a.shape < b.shape
  end)
  return meshes, straddling, program
end

return MeshCompiler
