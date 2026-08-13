-- Synthetic tests for the GX display-list decoder. Builds packed command
-- streams and checks primitive conversion, persistent state, matrix transforms,
-- opcode inventory, and the fatal error paths.

local Assert = require("tests.support.Assert")
local Gx = require("romdump.src.digest.nitro.GxDisplayList")

local T = {}

local function u32(v)
  v = v % 0x100000000
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- Build a packed display list from { {op=, p={...}}, ... }.
local function dl(cmds)
  local out = {}
  for i = 1, #cmds, 4 do
    local ops = {}
    local params = {}
    for j = 0, 3 do
      local c = cmds[i + j]
      ops[j + 1] = c and c.op or 0x00
      if c and c.p then
        for _, w in ipairs(c.p) do
          params[#params + 1] = w
        end
      end
    end
    out[#out + 1] = string.char(ops[1], ops[2], ops[3], ops[4])
    for _, w in ipairs(params) do
      out[#out + 1] = u32(w)
    end
  end
  return table.concat(out)
end

-- VTX_16 param words for integer-tile coordinates (raw = coord * 4096).
local function vtx16(x, y, z)
  local function raw(c)
    return math.floor(c * 4096) % 0x10000
  end
  return { op = 0x23, p = { raw(x) + raw(y) * 0x10000, raw(z) } }
end

local function fx32(c)
  return math.floor(c * 4096) % 0x100000000
end

function T.single_triangle()
  local r = assert(Gx.decode(dl({
    { op = 0x40, p = { 0 } }, -- BEGIN triangles
    vtx16(0, 0, 0),
    vtx16(1, 0, 0),
    vtx16(0, 2, 0),
    { op = 0x41 }, -- END
  })))
  Assert.equal(#r.vertices, 3)
  Assert.deepEqual(r.indices, { 0, 1, 2 })
  Assert.equal(r.vertices[2].x, 1)
  Assert.equal(r.vertices[3].y, 2)
  Assert.deepEqual(r.bounds.min, { 0, 0, 0 })
  Assert.deepEqual(r.bounds.max, { 1, 2, 0 })
end

function T.quad_becomes_two_triangles()
  local r = assert(Gx.decode(dl({
    { op = 0x40, p = { 1 } }, -- BEGIN quads
    vtx16(0, 0, 0),
    vtx16(1, 0, 0),
    vtx16(1, 1, 0),
    vtx16(0, 1, 0),
    { op = 0x41 },
  })))
  Assert.equal(#r.vertices, 4)
  Assert.deepEqual(r.indices, { 0, 1, 2, 0, 2, 3 })
end

function T.triangle_strip_winding()
  local r = assert(Gx.decode(dl({
    { op = 0x40, p = { 2 } }, -- BEGIN triangle strip
    vtx16(0, 0, 0),
    vtx16(1, 0, 0),
    vtx16(0, 1, 0),
    vtx16(1, 1, 0),
    { op = 0x41 },
  })))
  Assert.deepEqual(r.indices, { 0, 1, 2, 2, 1, 3 })
end

function T.vtx_diff_accumulates()
  -- A per-axis delta small enough to fit the signed 10-bit VTX_DIFF field.
  local delta = 100
  local word = delta + delta * 1024 + delta * 1048576
  local r = assert(Gx.decode(dl({
    { op = 0x40, p = { 0 } },
    vtx16(0, 0, 0),
    { op = 0x28, p = { word } }, -- VTX_DIFF
    vtx16(1, 1, 1),
    { op = 0x41 },
  })))
  local v = r.vertices[2]
  Assert.equal(v.x, 100 / 4096)
  Assert.equal(v.y, 100 / 4096)
  Assert.equal(v.z, 100 / 4096)
end

function T.matrix_translate_applies_to_positions()
  local r = assert(Gx.decode(dl({
    { op = 0x10, p = { 2 } }, -- MTX_MODE position&vector
    { op = 0x1C, p = { fx32(2), fx32(-3), fx32(0) } }, -- MTX_TRANS
    { op = 0x40, p = { 0 } },
    vtx16(0, 0, 0),
    vtx16(1, 0, 0),
    vtx16(0, 1, 0),
    { op = 0x41 },
  })))
  Assert.equal(r.vertices[1].x, 2)
  Assert.equal(r.vertices[1].y, -3)
  Assert.equal(r.vertices[2].x, 3)
end

function T.opcode_counts_and_names()
  local r = assert(Gx.decode(dl({
    { op = 0x40, p = { 0 } },
    vtx16(0, 0, 0),
    vtx16(1, 0, 0),
    vtx16(0, 1, 0),
    { op = 0x41 },
  })))
  Assert.equal(r.opcodeCounts[0x23], 3) -- three VTX_16
  Assert.equal(r.opcodeCounts[0x40], 1)
  Assert.equal(Gx.opcodeName(0x40), "BEGIN_VTXS")
end

function T.unknown_opcode_is_fatal()
  local bytes = string.char(0x99, 0, 0, 0)
  local r, err = Gx.decode(bytes)
  Assert.isNil(r)
  Assert.equal(assert(err).code, "GX_UNKNOWN_OPCODE")
  Assert.equal(assert(err).context.opcode, 0x99)
end

function T.unterminated_primitive_is_fatal()
  local r, err = Gx.decode(dl({ { op = 0x40, p = { 0 } }, vtx16(0, 0, 0) }))
  Assert.isNil(r)
  Assert.equal(assert(err).code, "GX_UNTERMINATED_PRIMITIVE")
end

function T.incomplete_triangle_is_fatal()
  local r, err = Gx.decode(dl({
    { op = 0x40, p = { 0 } },
    vtx16(0, 0, 0),
    vtx16(1, 0, 0),
    { op = 0x41 },
  }))
  Assert.isNil(r)
  Assert.equal(assert(err).code, "GX_INCOMPLETE_PRIMITIVE")
end

function T.externally_supplied_restore_slot_is_honored()
  -- An MTX_RESTORE inside the DL pulls from the restore stack supplied by the
  -- SBC evaluator rather than defaulting to identity.
  local translate = {
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    2,
    -3,
    0,
    1,
  }
  local r = assert(Gx.decode(
    dl({
      { op = 0x14, p = { 5 } }, -- MTX_RESTORE slot 5
      { op = 0x40, p = { 0 } },
      vtx16(0, 0, 0),
      vtx16(1, 0, 0),
      vtx16(0, 1, 0),
      { op = 0x41 },
    }),
    { restoreStack = { [5] = translate } }
  ))
  Assert.equal(r.vertices[1].x, 2)
  Assert.equal(r.vertices[1].y, -3)
  Assert.equal(r.vertices[2].x, 3)
end

-- ---- direction (vector) matrix ----

-- NORMAL encodes each component as a signed 10-bit 1.0.9 value, so the largest
-- magnitude it can carry is 511/512; the decoder renormalizes the transformed
-- result, which is what lets these cases assert exact unit components.
local function normalCmd(x, y, z)
  local function raw(c)
    return math.floor(c * 511 + 0.5) % 1024
  end
  return { op = 0x21, p = { raw(x) + raw(y) * 1024 + raw(z) * 1048576 } }
end

-- The DS vector matrix is 3x3, so a pure translation moves vertices but leaves
-- normals alone.
function T.translation_does_not_rotate_normals()
  local r = assert(Gx.decode(dl({
    { op = 0x1C, p = { fx32(2), fx32(-3), fx32(0) } }, -- MTX_TRANS
    normalCmd(0, 1, 0),
    { op = 0x40, p = { 0 } },
    vtx16(0, 0, 0),
    vtx16(1, 0, 0),
    vtx16(0, 1, 0),
    { op = 0x41 },
  })))
  local v = r.vertices[1]
  Assert.equal(v.x, 2)
  Assert.equal(v.ny, 1)
  Assert.equal(v.nx, 0)
  Assert.equal(v.nz, 0)
end

-- A rotation in the incoming SBC matrix must reach the normals: 90 degrees
-- about Y sends +X to -Z.
function T.node_rotation_reaches_normals()
  local rotY90 = {
    0,
    0,
    -1,
    0,
    0,
    1,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
  }
  local r = assert(Gx.decode(
    dl({
      normalCmd(1, 0, 0),
      { op = 0x40, p = { 0 } },
      vtx16(1, 0, 0),
      vtx16(0, 1, 0),
      vtx16(0, 0, 1),
      { op = 0x41 },
    }),
    { matrix = rotY90 }
  ))
  local v = r.vertices[1]
  Assert.equal(v.nx, 0)
  Assert.equal(v.ny, 0)
  Assert.equal(v.nz, -1)
end

-- A scaled matrix changes vertex positions but leaves the baked normal a unit
-- direction for the engine's own lighting.
function T.scaled_matrix_keeps_normals_unit_length()
  local r = assert(Gx.decode(dl({
    { op = 0x1B, p = { fx32(4), fx32(4), fx32(4) } }, -- MTX_SCALE
    normalCmd(0, 1, 0),
    { op = 0x40, p = { 0 } },
    vtx16(1, 0, 0),
    vtx16(0, 1, 0),
    vtx16(0, 0, 1),
    { op = 0x41 },
  })))
  Assert.equal(r.vertices[1].x, 4)
  Assert.equal(r.vertices[1].ny, 1)
end

-- MTX_MODE position-only leaves the vector matrix behind, so the normal keeps
-- the orientation the position matrix had before the divergence.
function T.position_only_matrix_mode_does_not_move_normals()
  local r = assert(Gx.decode(dl({
    { op = 0x10, p = { 1 } }, -- MTX_MODE position
    { op = 0x1B, p = { fx32(4), fx32(1), fx32(1) } }, -- MTX_SCALE, position only
    normalCmd(1, 0, 0),
    { op = 0x40, p = { 0 } },
    vtx16(1, 0, 0),
    vtx16(0, 1, 0),
    vtx16(0, 0, 1),
    { op = 0x41 },
  })))
  Assert.equal(r.vertices[1].x, 4)
  Assert.equal(r.vertices[1].nx, 1)
end

function T.projection_matrix_mode_is_fatal()
  local r, err = Gx.decode(dl({ { op = 0x10, p = { 0 } } }))
  Assert.isNil(r)
  Assert.equal(assert(err).code, "GX_PROJECTION_MATRIX_MODE_UNSUPPORTED")
end

return { tests = T }
