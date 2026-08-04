-- MeshCompiler: replays a shape display list with the material-seeded GX state,
-- folds posScale + tile calibration into positions, resolves a color source per
-- vertex, carries the material's effective polygon-attr word, and rejects both a
-- missing shape and an unsupported in-display-list command.

local Assert = require("tests.support.Assert")
local MeshCompiler = require("src.import.MeshCompiler")
local Errors = require("src.import.Errors")
local NB = require("tests.support.NitroBuilder")

local T = {}

-- Pack a VTX_16 (two words) from fx16 1.3.12 coordinates.
local function vtx16(x, y, z)
  local function raw(c) return math.floor(c * 4096) % 0x10000 end
  return NB.u32(raw(x) + raw(y) * 0x10000) .. NB.u32(raw(z))
end

-- A one-triangle display list with an optional leading COLOR or NORMAL command.
-- lead: "color" | "normal" | nil.
local function triangleDL(lead)
  if lead == "color" then
    -- COLOR, BEGIN, VTX, VTX | VTX, END, NOP, NOP
    return string.char(0x20, 0x40, 0x23, 0x23)
      .. NB.u32(31) .. NB.u32(0) .. vtx16(1, 0, 0) .. vtx16(0, 0, 1)
      .. string.char(0x23, 0x41, 0, 0) .. vtx16(0, 0, 0)
  elseif lead == "normal" then
    return string.char(0x21, 0x40, 0x23, 0x23)
      .. NB.u32(0) .. NB.u32(0) .. vtx16(1, 0, 0) .. vtx16(0, 0, 1)
      .. string.char(0x23, 0x41, 0, 0) .. vtx16(0, 0, 0)
  else -- no color/normal: vertices inherit the material's set-vertex-color seed
    return string.char(0x40, 0x23, 0x23, 0x23)
      .. NB.u32(0) .. vtx16(1, 0, 0) .. vtx16(0, 0, 1) .. vtx16(0, 0, 0)
      .. string.char(0x41, 0, 0, 0)
  end
end

local function material(overrides)
  local m = {
    index = 3, name = "mat", setVertexColor = true,
    diffuseRgb555 = 31, ambientRgb555 = 0, specularRgb555 = 0, emissionRgb555 = 0,
    polyAttrRaw = 0x001F00C1, polyAttrMask = 0x3F1FF8FF,
    texImageParamRaw = 0, texImageParamMask = 0xFFFFFFFF, flagsRaw = 0x140,
  }
  for k, v in pairs(overrides or {}) do m[k] = v end
  return m
end

local function model(lead, materialOverrides)
  return {
    name = "m",
    info = { posScale = 64 },
    materials = { material(materialOverrides) },
    shapes = { { index = 0, name = "s", displayListBytes = triangleDL(lead) } },
    sbc = { draws = { { nodeIndex = 0, materialIndex = 3, shapeIndex = 0, materialReapplied = true } } },
  }
end

function T.folds_posscale_and_carries_attributes()
  local b = MeshCompiler.compile(model("color"))
  Assert.equal(#b, 1)
  Assert.equal(b[1].materialIndex, 3)
  Assert.equal(b[1].nodeIndex, 0)
  Assert.equal(b[1].submissionIndex, 1)
  Assert.isTrue(math.abs(b[1].vertices[1].x - (1 * 64 / 16)) < 1e-9, "x scaled by posScale/16")
  Assert.deepEqual(b[1].indices, { 0, 1, 2 })
end

function T.resolves_literal_color_source()
  local b = MeshCompiler.compile(model("color"))
  for _, v in ipairs(b[1].vertices) do
    Assert.equal(v.colorSource, 0) -- LITERAL
    Assert.equal(v.r, 255)         -- COLOR rgb555(31,0,0)
  end
end

function T.resolves_normal_lit_source()
  local b = MeshCompiler.compile(model("normal"))
  for _, v in ipairs(b[1].vertices) do
    Assert.equal(v.colorSource, 1) -- NORMAL_LIT
  end
end

function T.seeds_field_diffuse_when_no_color_or_normal()
  local b = MeshCompiler.compile(model(nil))
  for _, v in ipairs(b[1].vertices) do
    Assert.equal(v.colorSource, 2) -- FIELD_DIFFUSE from set-vertex-color material
    Assert.equal(v.r, 255)         -- material diffuse rgb555(31,0,0)
  end
end

function T.carries_effective_polygon_attr()
  local b = MeshCompiler.compile(model("color"))
  -- Full field global 0 + material mask 0x3F1FF8FF over raw 0x001F00C1.
  Assert.equal(b[1].polygonAttrRaw, 0x001F00C1)
end

function T.missing_shape_raises()
  local m = model("color")
  m.sbc.draws[1].shapeIndex = 9
  local ok, err = pcall(MeshCompiler.compile, m)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MAP_COMPILE_MISSING_SHAPE", "raises")
end

function T.unsupported_dl_command_raises()
  -- Inject a SHININESS (0x34, 32 param words) before END: unsupported for fields.
  local dl = string.char(0x20, 0x40, 0x23, 0x23)
    .. NB.u32(31) .. NB.u32(0) .. vtx16(1, 0, 0) .. vtx16(0, 0, 1)
    .. string.char(0x23, 0x34, 0x41, 0) .. vtx16(0, 0, 0) .. string.rep(NB.u32(0), 32)
  local m = model("color")
  m.shapes[1].displayListBytes = dl
  local ok, err = pcall(MeshCompiler.compile, m)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MAP_COMPILE_SHININESS_UNSUPPORTED",
    "rejects in-DL shininess")
end

function T.unsupported_polygon_mode_raises()
  -- Mode bits 4-5 = 2 (toon/highlight) is not supported for field rendering.
  local m = model("color", { polyAttrRaw = 0x001F00E1 })
  local ok, err = pcall(MeshCompiler.compile, m)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MAP_COMPILE_UNSUPPORTED_POLYGON_MODE",
    "rejects toon polygon mode")
end

return T
