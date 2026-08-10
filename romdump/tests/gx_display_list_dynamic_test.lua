-- Tests for GxDisplayList's transform-preserving (dynamic) mode: display
-- lists decode into segments whose vertices are baked only through the
-- display-list-local matrix ops, with the pose-dependent transform deferred
-- to per-segment sources. Static mode must remain bit-for-bit unchanged.

local Assert = require("tests.support.Assert")
local GxDisplayList = require("romdump.src.digest.nitro.GxDisplayList")
local NB = require("tests.support.NitroBuilder")

local T = {}

local function u32(v)
  return NB.u32(v)
end

-- Pack a display list: an array of command groups, each { {opcodes...}, {paramWords...} }.
local function pack(groups)
  local parts = {}
  for _, group in ipairs(groups) do
    local ops = { 0, 0, 0, 0 }
    for i, op in ipairs(group[1]) do
      ops[i] = op
    end
    parts[#parts + 1] = string.char(ops[1], ops[2], ops[3], ops[4])
    for _, w in ipairs(group[2] or {}) do
      parts[#parts + 1] = u32(w)
    end
  end
  return table.concat(parts)
end

-- A VTX_16 parameter word: x in low 16 bits (1.3.12), y in high 16.
local function vtx16xy(x, y)
  return math.floor(x * 4096) % 0x10000 + math.floor(y * 4096) % 0x10000 * 0x10000
end

-- One triangle: BEGIN + three VTX_16 in one command group, then END.
local function triangle(vertices)
  local ops = { 0x40, 0x23, 0x23, 0x23 }
  local words = { 0 }
  for _, v in ipairs(vertices) do
    words[#words + 1] = vtx16xy(v[1], v[2])
    words[#words + 1] = v[3]
  end
  return pack({ { ops, words } }) .. pack({ { { 0x41 } } })
end

local function decode(bytes, opts)
  local result, err = GxDisplayList.decode(bytes, opts)
  if not result then
    error(err)
  end
  return result
end

local function assertVertex(segment, index, x, y, z)
  local v = segment.vertices[index + 1]
  Assert.isTrue(v ~= nil, "segment vertex " .. index .. " exists")
  if math.abs(v.x - x) > 1e-9 or math.abs(v.y - y) > 1e-9 or math.abs(v.z - z) > 1e-9 then
    error(
      "vertex "
        .. index
        .. ": expected ("
        .. x
        .. ","
        .. y
        .. ","
        .. z
        .. "), got ("
        .. v.x
        .. ","
        .. v.y
        .. ","
        .. v.z
        .. ")"
    )
  end
end

-- ---- basic behavior ----

function T.one_segment_with_the_draw_source()
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true, requireColorSource = true })
  Assert.equal(#geom.segments, 1)
  local segment = geom.segments[1]
  Assert.equal(segment.positionSource, "draw")
  Assert.equal(#segment.vertices, 3)
  Assert.equal(#segment.indices, 3)
  -- Vertices stay in pre-draw space: identity local ops bake nothing.
  assertVertex(segment, 0, 0, 0, 0)
  assertVertex(segment, 1, 1, 0, 0)
  assertVertex(segment, 2, 0, 1, 0)
end

function T.post_multiply_ops_bake_into_the_vertices()
  -- MTX_MULT_3x3 scale (2,2,2) then the triangle: the local scale is baked.
  local dl = pack({
    { { 0x1A }, { 2 * 4096, 0, 0, 0, 2 * 4096, 0, 0, 0, 2 * 4096 } },
  }) .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 1)
  Assert.equal(geom.segments[1].positionSource, "draw")
  assertVertex(geom.segments[1], 1, 2, 0, 0)
  assertVertex(geom.segments[1], 2, 0, 2, 0)
end

function T.literal_load_bakes_into_the_vertices()
  -- MTX_LOAD_4x3 with a +10 x translation: the loaded matrix replaces the
  -- draw matrix, so its effect is constant and bakes into the vertices.
  local dl = pack({
    { { 0x17 }, { 4096, 0, 0, 0, 4096, 0, 0, 0, 4096, 10 * 4096, 0, 0 } },
  }) .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 1)
  assertVertex(geom.segments[1], 0, 10, 0, 0)
  assertVertex(geom.segments[1], 1, 11, 0, 0)
end

-- ---- segment boundaries ----

local MTX_RESTORE = { { 0x14 }, { 3 } }
local MTX_MODE_POSVEC = { { 0x10 }, { 2 } }

function T.matrix_restore_splits_a_segment_with_a_slot_source()
  -- Triangle, MTX_RESTORE slot 3, second triangle: two segments, the second
  -- carrying the slot source.
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
    .. pack({ MTX_RESTORE })
    .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 2)
  local first, second = geom.segments[1], geom.segments[2]
  Assert.equal(first.positionSource, "draw")
  Assert.equal(second.positionSource.slot, 3)
  Assert.equal(#first.vertices, 3)
  Assert.equal(#second.vertices, 3)
  assertVertex(second, 0, 0, 0, 0)
end

function T.matrix_push_pop_restores_the_prior_source()
  -- Push (draw), restore slot 3 (slot source), pop: back to the draw source,
  -- so a third triangle forms its own "draw" segment.
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
    .. pack({ { { 0x11 } }, MTX_RESTORE })
    .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
    .. pack({ { { 0x12 }, { 0 } } })
    .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 3)
  Assert.equal(geom.segments[1].positionSource, "draw")
  Assert.equal(geom.segments[2].positionSource.slot, 3)
  Assert.equal(geom.segments[3].positionSource, "draw")
end

function T.segment_indices_are_local_to_each_segment()
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
    .. pack({ MTX_RESTORE })
    .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  local first, second = geom.segments[1], geom.segments[2]
  Assert.equal(#first.indices, 3)
  Assert.equal(#second.indices, 3)
  -- Both segments index their own vertices from zero.
  for _, i in ipairs(second.indices) do
    Assert.isTrue(i < 3, "second segment indices are local")
  end
end

-- ---- rejected edges ----

function T.rejects_matrix_store_inside_the_list()
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } }) .. pack({ { { 0x13 }, { 5 } } })
  local err = Assert.throws(function()
    decode(dl, { dynamic = true })
  end)
  Assert.equal(err.code, "GX_DYNAMIC_MATRIX_STORE_UNSUPPORTED")
end

function T.rejects_matrix_ops_under_position_only_mode()
  -- MTX_MODE POSITION (1), then a scale op: the position and direction
  -- matrices would diverge.
  local dl = pack({ { { 0x10 }, { 1 } }, { { 0x1B }, { 2 * 4096, 2 * 4096, 2 * 4096 } } })
  local err = Assert.throws(function()
    decode(dl, { dynamic = true })
  end)
  Assert.equal(err.code, "GX_DYNAMIC_POSITION_ONLY_MATRIX_OP_UNSUPPORTED")
end

function T.splits_a_run_at_a_matrix_boundary()
  -- BEGIN, VTX, RESTORE, VTX x2, END: the hardware re-homes the transform at
  -- submission, so the run is split at the boundary; the straddling
  -- triangle's leading vertex is carried into the next segment, where the
  -- triangle renders rigidly under the slot source.
  local dl = pack({
    { { 0x40, 0x23 }, { 0, vtx16xy(0, 0), 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23 }, { vtx16xy(1, 0), 0, vtx16xy(0, 1), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 2)
  Assert.equal(geom.segments[1].positionSource, "draw")
  Assert.equal(geom.segments[2].positionSource.slot, 3)
  -- The old segment keeps the lone leading vertex (no indices); the new
  -- segment carries it and renders the triangle rigidly in the slot frame.
  Assert.equal(#geom.segments[1].vertices, 1)
  Assert.equal(#geom.segments[1].indices, 0)
  Assert.equal(#geom.segments[2].vertices, 3)
  Assert.equal(#geom.segments[2].indices, 3)
  assertVertex(geom.segments[2], 0, 0, 0, 0)
  Assert.equal(geom.straddlingPrimitives, 1)
end

function T.boundary_before_any_vertex_keeps_the_run_whole()
  -- BEGIN, RESTORE, then vertices: the run has no vertices at the boundary,
  -- so nothing straddles; the whole run lands in the new segment.
  local dl = pack({
    { { 0x40 }, { 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23, 0x23 }, { vtx16xy(0, 0), 0, vtx16xy(1, 0), 0, vtx16xy(0, 1), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 1)
  local segment = geom.segments[1]
  Assert.equal(segment.positionSource.slot, 3)
  Assert.equal(#segment.vertices, 3)
  Assert.equal(#segment.indices, 3)
  Assert.equal(geom.straddlingPrimitives, 0)
end

function T.straddling_quads_are_carried_into_the_new_segment()
  -- BEGIN(separate quads), two quads, RESTORE, one quad, END: the first
  -- segment keeps its complete quad; the quad spanning the boundary has its
  -- leading vertices carried so it renders rigidly in the new segment under
  -- the slot source.
  local dl = pack({
    { { 0x40, 0x23, 0x23 }, { 1, vtx16xy(0, 0), 0, vtx16xy(1, 0), 0 } },
    { { 0x23, 0x23 }, { vtx16xy(1, 1), 0, vtx16xy(0, 1), 0 } },
    { { 0x23, 0x23 }, { vtx16xy(2, 0), 0, vtx16xy(3, 0), 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23 }, { vtx16xy(4, 1), 0, vtx16xy(3, 1), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 2)
  local first, second = geom.segments[1], geom.segments[2]
  Assert.equal(#first.vertices, 6)
  Assert.equal(#first.indices, 6)
  Assert.equal(second.positionSource.slot, 3)
  -- The carried leading vertices (copies of the old segment's v4/v5) plus
  -- the two trailing vertices form the straddling quad, rigid in the slot
  -- frame.
  Assert.equal(#second.vertices, 4)
  Assert.equal(#second.indices, 6)
  assertVertex(second, 0, 2, 0, 0)
  assertVertex(second, 1, 3, 0, 0)
  Assert.equal(geom.straddlingPrimitives, 1)
end

function T.triangle_strip_winding_continues_across_a_boundary()
  -- A triangle strip split after its first triangle: the carried vertices
  -- keep the strip's alternating winding (the DS computes it from the
  -- running vertex index, which the split must carry).
  local dl = pack({
    { { 0x40, 0x23, 0x23 }, { 2, vtx16xy(0, 0), 0, vtx16xy(1, 0), 0 } },
    { { 0x23 }, { vtx16xy(0, 1), 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23, 0x23 }, { vtx16xy(1, 1), 0, vtx16xy(2, 1), 0, vtx16xy(2, 0), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 2)
  local first, second = geom.segments[1], geom.segments[2]
  Assert.equal(#first.vertices, 3)
  -- First strip triangle: (0,1,2) with the even winding.
  Assert.deepEqual(first.indices, { 0, 1, 2 })
  -- The second segment carries copies of the last two vertices and
  -- continues the strip: local (1,0,2) for the triangle ending at global
  -- vertex 3, matching the DS's alternating winding.
  Assert.equal(#second.vertices, 5)
  Assert.deepEqual(second.indices, { 1, 0, 2, 1, 2, 3, 3, 2, 4 })
  Assert.equal(geom.straddlingPrimitives, 1)
end

-- ---- static mode is unchanged ----

function T.static_mode_still_bakes_the_supplied_matrix()
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local matrix = { 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 10, 0, 0, 1 }
  local geom = decode(dl, { matrix = matrix })
  Assert.equal(geom.vertices[2].x, 12)
  Assert.equal(geom.segments, nil)
end

function T.static_and_dynamic_decode_agree_on_color_state()
  local dl = pack({ { { 0x20 }, { 0x7C00 } } }) .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local static = decode(dl, { requireColorSource = true })
  local dynamic = decode(dl, { dynamic = true, requireColorSource = true })
  local sv = static.vertices[1]
  local dv = dynamic.segments[1].vertices[1]
  Assert.equal(dv.r, sv.r)
  Assert.equal(dv.g, sv.g)
  Assert.equal(dv.b, sv.b)
  Assert.equal(dv.colorSource, sv.colorSource)
end

return T
