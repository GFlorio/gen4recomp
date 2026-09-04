-- Terrain boundary conformance: cross-batch topology repair for separately
-- rendered terrain batches.
--
-- Outdoor terrain is drawn as one batch per material. When a coarse batch
-- carries boundary edge A-B while the same batch or a touching batch breaks
-- the same span at interior vertices P1..Pn, host point-sampling can disagree along the two
-- differently segmented but collinear edges and leave an isolated sample
-- owned by neither batch. The producer repair splits the coarse boundary
-- topology so both sides express the same breakpoints, without merging
-- materials, batches, or render state. These tests pin that contract against
-- the pure producer module using hand-built compiled-batch fixtures in tile
-- units on the y=1 plane; no ROM data is involved.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local MeshWriter = require("libs.assets.src.MeshWriter")

local CONFORMER_MODULE = "romdump.src.digest.TerrainBoundaryConformer"

local T = {}

-- The producer module under test. Every case requires it lazily so the suite
-- loads even before the repair exists and each failure names the missing
-- behavior rather than a load error.
local function conformer()
  local ok, mod = pcall(require, CONFORMER_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table",
    "terrain boundary repair is missing: a coarse boundary edge is not split at touching-batch breakpoints"
  )
  Assert.equal(type(mod.conform), "function", "terrain boundary repair must expose conform(batches, context)")
  Assert.equal(
    type(mod.findTJunctions),
    "function",
    "terrain boundary repair must expose a findTJunctions(batches) inspection helper"
  )
  return mod --[[@as table]]
end

local function context()
  return {
    role = "map",
    mapSymbol = "MAP_FIXTURE",
    modelArchive = "land_data",
    modelMemberId = 0,
    modelName = "fixture",
  }
end

-- Conform, tolerating an in-place repair: the contract is the returned batch
-- list, whether it is a fresh list or the input mutated in place.
local function conform(batches)
  local out = conformer().conform(batches, context())
  return out or batches
end

local function junctions(batches)
  return conformer().findTJunctions(batches) or {}
end

local function V(x, y, z, o)
  o = o or {}
  return {
    x = x,
    y = y,
    z = z,
    u = o.u or 0,
    v = o.v or 0,
    nx = o.nx or 0,
    ny = o.ny or 1,
    nz = o.nz or 0,
    r = o.r or 255,
    g = o.g or 255,
    b = o.b or 255,
    a = o.a or 255,
    colorSource = o.colorSource or 0,
  }
end

local function B(vertices, indices, materialIndex)
  return {
    nodeIndex = 0,
    materialIndex = materialIndex or 0,
    shapeIndex = 0,
    polygonAttrRaw = 0x001F00C1,
    transformMode = "static",
    vertices = vertices,
    indices = indices,
  }
end

local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[deepcopy(k)] = deepcopy(v)
  end
  return out
end

-- How many vertices sit exactly at (x, y, z).
local function countAt(batches, x, y, z)
  local n = 0
  for _, batch in ipairs(batches) do
    for _, v in ipairs(batch.vertices) do
      if v.x == x and v.y == y and v.z == z then
        n = n + 1
      end
    end
  end
  return n
end

local function vertexAt(batch, x, y, z)
  for _, v in ipairs(batch.vertices) do
    if v.x == x and v.y == y and v.z == z then
      return v
    end
  end
  return nil
end

-- Signed triangle area in the y=1 plane (the x/z projection), for winding and
-- degeneracy checks on output triangles.
local function signedArea(a, b, c)
  return 0.5 * ((b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z))
end

local function triangleAreas(batch)
  local areas = {}
  for i = 1, #batch.indices, 3 do
    local a = batch.vertices[batch.indices[i] + 1]
    local b = batch.vertices[batch.indices[i + 1] + 1]
    local c = batch.vertices[batch.indices[i + 2] + 1]
    areas[#areas + 1] = signedArea(a, b, c)
  end
  return areas
end

-- A coarse quad x in [-4,0], z in [0,4] with one unbroken boundary edge along
-- x=0, plus a fine neighbor x in [0,4] breaking that span at P=(0,1,2).
local function singleSeam(materialIndex)
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 4),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 }, materialIndex)
  local fine = B({
    V(4, 1, 0),
    V(0, 1, 0),
    V(4, 1, 2),
    V(0, 1, 2),
    V(4, 1, 4),
    V(0, 1, 4),
  }, { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5 }, materialIndex)
  return { coarse, fine }
end

function T.splits_a_single_t_junction_and_reports_no_remaining_junctions()
  local before = singleSeam()
  Assert.isTrue(#junctions(before) >= 1, "the deliberate T-seam must be diagnosed before repair")

  local after = conform(deepcopy(before))
  Assert.equal(#junctions(after), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(countAt({ after[1] }, 0, 1, 2), 1, "the coarse side expresses the shared breakpoint exactly once")
  Assert.equal(#after[1].indices, 9, "the one split triangle becomes two; its neighbor is untouched")
  Assert.equal(#after[2].indices, 12, "the fine side keeps its four triangles")
end

-- One coarse span z in [0,6] met by breakpoints at z=2 and z=4.
local function multiSplit()
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 6),
    V(-4, 1, 6),
  }, { 0, 1, 2, 0, 2, 3 })
  local fine = B({
    V(4, 1, 0),
    V(0, 1, 0),
    V(4, 1, 2),
    V(0, 1, 2),
    V(4, 1, 4),
    V(0, 1, 4),
    V(4, 1, 6),
    V(0, 1, 6),
  }, { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5, 5, 4, 6, 5, 6, 7 })
  return { coarse, fine }
end

function T.inserts_multiple_split_points_deterministically()
  local first = conform(deepcopy(multiSplit()))
  Assert.equal(#junctions(first), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(countAt({ first[1] }, 0, 1, 2), 1, "the first breakpoint is expressed on the coarse side")
  Assert.equal(countAt({ first[1] }, 0, 1, 4), 1, "the second breakpoint is expressed on the coarse side")

  local second = conform(deepcopy(multiSplit()))
  Assert.deepEqual(second, first, "the same input conforms byte-identically across runs")
end

-- Side A breaks the shared span at z=2, side B at z=1: both must finish with
-- the union {0,1,2,4}.
local function unionSeam()
  local a = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(-4, 1, 2),
    V(0, 1, 2),
    V(-4, 1, 4),
    V(0, 1, 4),
  }, { 0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4 })
  local b = B({
    V(0, 1, 0),
    V(4, 1, 0),
    V(0, 1, 1),
    V(4, 1, 1),
    V(0, 1, 4),
    V(4, 1, 4),
  }, { 0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4 })
  return { a, b }
end

function T.conforms_both_sides_to_the_union_of_breakpoints()
  local after = conform(deepcopy(unionSeam()))
  Assert.equal(#junctions(after), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(countAt({ after[1] }, 0, 1, 1), 1, "side A adopts side B's breakpoint")
  Assert.equal(countAt({ after[2] }, 0, 1, 2), 1, "side B adopts side A's breakpoint")
end

-- Both sides already break the span at z=2: identical segmentation.
local function conformingSeam()
  local a = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(-4, 1, 2),
    V(0, 1, 2),
    V(-4, 1, 4),
    V(0, 1, 4),
  }, { 0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4 })
  local b = B({
    V(0, 1, 0),
    V(4, 1, 0),
    V(0, 1, 2),
    V(4, 1, 2),
    V(0, 1, 4),
    V(4, 1, 4),
  }, { 0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4 })
  return { a, b }
end

function T.leaves_already_conforming_boundaries_unchanged()
  local input = conformingSeam()
  Assert.equal(#junctions(input), 0, "matching segmentation starts clean")
  local after = conform(deepcopy(input))
  Assert.equal(#after[1].vertices, 6, "no vertex churn on side A")
  Assert.equal(#after[1].indices, 12, "no index churn on side A")
  Assert.equal(#after[2].vertices, 6, "no vertex churn on side B")
  Assert.equal(#after[2].indices, 12, "no index churn on side B")
  Assert.deepEqual(after, input, "conforming input round-trips exactly")
end

-- A vertex collinear with the seam but interior to its own batch (a triangle
-- fan center) must not trigger a split: only boundary vertices of other
-- batches are candidates.
local function interiorVertexFixture()
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 4),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  local center = V(0, 1, 2)
  local r1, r2, r3, r4 = V(-2, 1, -2), V(4, 1, -2), V(4, 1, 6), V(-2, 1, 6)
  local fan = B({ center, r1, r2, r3, r4 }, { 0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 1 })
  return { coarse, fan }
end

function T.ignores_interior_vertices_of_other_batches()
  local after = conform(deepcopy(interiorVertexFixture()))
  Assert.equal(#after[1].vertices, 4, "an interior vertex of another batch splits nothing")
  Assert.equal(#after[1].indices, 6, "an interior vertex of another batch splits nothing")
  Assert.equal(#junctions(after), 0, "interior vertices are not boundary T-junctions")
end

-- A boundary vertex 1e-3 tiles off the edge exceeds any sane producer
-- collinearity tolerance (orders around 1e-9 tile units) by orders of
-- magnitude, so it must be rejected, never snapped.
local function nearMissFixture()
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 4),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  local fine = B({
    V(4, 1, 0),
    V(0.001, 1, 0),
    V(4, 1, 2),
    V(0.001, 1, 2),
    V(4, 1, 4),
    V(0.001, 1, 4),
  }, { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5 })
  return { coarse, fine }
end

function T.rejects_near_miss_points_beyond_tolerance()
  local after = conform(deepcopy(nearMissFixture()))
  Assert.equal(#after[1].vertices, 4, "a near-miss point must not split the edge")
  Assert.equal(#after[1].indices, 6, "a near-miss point must not split the edge")
  Assert.equal(countAt(after, 0.001, 1, 2), 1, "the off-edge vertex stays on its own side only")
  Assert.equal(#junctions(after), 0, "a rejected near-miss is not a remaining T-junction")
end

function T.does_not_duplicate_existing_endpoints()
  local a = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 4),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  -- The neighbor shares the span endpoints exactly and adds no interior break.
  local b = B({
    V(0, 1, 0),
    V(4, 1, 0),
    V(4, 1, 4),
    V(0, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  local after = conform({ a, b })
  Assert.equal(#after[1].vertices, 4, "shared endpoints create no zero-length segment")
  Assert.equal(#after[1].indices, 6, "shared endpoints create no zero-length segment")
  for _, batch in ipairs(after) do
    for _, area in ipairs(triangleAreas(batch)) do
      Assert.isTrue(area > 1e-12, "no degenerate triangle may appear")
    end
  end
  Assert.equal(#junctions(after), 0, "shared endpoints are already conforming")
end

-- One triangle carrying a split point on two of its boundary edges.
local function twoEdgeSplit()
  local single = B({ V(0, 1, 0), V(0, 1, 4), V(4, 1, 2) }, { 0, 1, 2 })
  local other = B({ V(0, 1, 1), V(2, 1, 3), V(0, 1, 4) }, { 0, 1, 2 })
  return { single, other }
end

function T.retriangulates_a_triangle_split_on_two_edges()
  local input = twoEdgeSplit()
  local originalArea = triangleAreas(input[1])[1]
  local after = conform(deepcopy(input))
  Assert.equal(#junctions(after), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(#after[1].indices, 9, "one triangle split on two edges becomes three")
  local areas = triangleAreas(after[1])
  local total = 0
  for _, area in ipairs(areas) do
    Assert.isTrue(math.abs(area) > 1e-12, "retriangulation emits no zero-area triangle")
    Assert.isTrue(area * originalArea > 0, "retriangulation preserves the original winding")
    total = total + area
  end
  Assert.isTrue(math.abs(total - originalArea) < 1e-9, "retriangulation covers exactly the original area")
  Assert.equal(#after[2].indices, 3, "the fine triangle needs no repair of its own")
end

-- Attribute interpolation at t=0.25 along B->C: position is copied exactly
-- from the shared breakpoint; uv/normal/color interpolate in the coarse
-- batch's stored domains; the categorical colorSource is preserved.
local function attributeFixture(colorSourceA, colorSourceB)
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0, { u = 0, v = 8, nx = 10, r = 10, g = 20, b = 30, a = 40, colorSource = colorSourceA }),
    V(0, 1, 4, { u = 8, v = 0, nx = 30, r = 50, g = 60, b = 70, a = 200, colorSource = colorSourceB }),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  local fine = B({
    V(4, 1, 0),
    V(0, 1, 0),
    V(4, 1, 1),
    V(0, 1, 1),
    V(4, 1, 4),
    V(0, 1, 4),
  }, { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5 })
  return { coarse, fine }
end

function T.interpolates_inserted_vertex_attributes_in_the_coarse_domain()
  local after = conform(attributeFixture(2, 2))
  local inserted = vertexAt(after[1], 0, 1, 1)
  Assert.notNil(inserted, "the coarse side gains the shared breakpoint")
  ---@cast inserted table
  Assert.equal(inserted.u, 2, "u interpolates from the coarse edge endpoints")
  Assert.equal(inserted.v, 6, "v interpolates from the coarse edge endpoints")
  Assert.equal(inserted.nx, 15, "normals interpolate in the stored raw domain")
  Assert.equal(inserted.r, 20, "byte color interpolates deterministically")
  Assert.equal(inserted.g, 30, "byte color interpolates deterministically")
  Assert.equal(inserted.b, 40, "byte color interpolates deterministically")
  Assert.equal(inserted.a, 80, "byte alpha interpolates deterministically")
  Assert.equal(inserted.colorSource, 2, "the categorical color source is preserved, never averaged")
end

function T.fails_loudly_on_categorical_color_source_conflict()
  local err = Assert.throws(function()
    conform(attributeFixture(0, 1))
  end, "mismatched endpoint color sources must fail instead of silently choosing one")
  Assert.isTrue(Errors.is(err), "the conflict is a structured producer error")
  Assert.isTrue(type(err.message) == "string" and #err.message > 0, "the conflict carries a message")
  Assert.isTrue(type(err.context) == "table", "the conflict carries source context")
end

-- One batch whose own boundary turns at P=(0,1,1) while its spanning edge
-- A-B passes straight through: the spanning edge splits at the shared
-- breakpoint exactly as for a touching batch, because host sampling
-- disagrees along differently segmented collinear edges wherever the
-- breakpoint lives.
function T.repairs_a_same_batch_t_junction_and_preserves_area_and_winding()
  local batch = B({
    V(0, 1, 0),
    V(0, 1, 4),
    V(4, 1, 2),
    V(0, 1, 1),
    V(-4, 1, 2),
  }, { 0, 1, 2, 3, 1, 4 })
  local input = { batch }
  Assert.isTrue(#junctions(input) >= 1, "the same-batch T arrangement must be diagnosed before repair")
  local beforeAreas = triangleAreas(input[1])
  local beforeTotal = beforeAreas[1] + beforeAreas[2]
  local after = conform(deepcopy(input))
  Assert.equal(#junctions(after), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(#after[1].vertices, 6, "the spanning edge gains the shared breakpoint")
  Assert.equal(#after[1].indices, 9, "the split triangle becomes two; its neighbor is untouched")
  Assert.equal(countAt(after, 0, 1, 1), 2, "the shared breakpoint is expressed on both sides of the split")
  local areas = triangleAreas(after[1])
  local total = 0
  for _, area in ipairs(areas) do
    Assert.isTrue(math.abs(area) > 1e-12, "retriangulation emits no zero-area triangle")
    total = total + area
  end
  Assert.isTrue(math.abs(total - beforeTotal) < 1e-9, "retriangulation covers exactly the original area")
  Assert.isTrue(
    areas[1] * beforeAreas[1] > 0 and areas[2] * beforeAreas[1] > 0,
    "the split preserves the original winding"
  )
  Assert.equal(areas[3], beforeAreas[2], "the untouched triangle keeps its exact area")
  Assert.deepEqual(conform(deepcopy(input)), after, "the same input conforms byte-identically across runs")
  local again = conformer().conform(deepcopy(after), context()) or after
  Assert.deepEqual(again, after, "repair is idempotent")
end

-- Two crossing boundary spans: batch one owns the breakpoint P=(-2,1,14)
-- as a boundary corner while batch two spans straight through it along
-- z=14, and batch one's own edge U0-U1 spans straight through P along
-- x=-2. Both breakpoints are visible before repair -- one same-batch, one
-- across batches -- so one closure pass splits both spans; the split
-- diagonals are internal tessellation edges, so no further breakpoint
-- appears and a second conform changes nothing.
function T.repairs_same_and_cross_batch_breakpoints_to_closure()
  local first = B({
    V(-2, 1, 16),
    V(-2, 1, 12),
    V(2, 1, 14),
    V(-2, 1, 14),
    V(-6, 1, 15),
  }, { 0, 1, 2, 0, 3, 4 })
  local second = B({
    V(-7, 1, 14),
    V(-1, 1, 14),
    V(-4, 1, 18),
  }, { 0, 1, 2 })
  local before = { first, second }
  Assert.equal(#junctions(before), 2, "the same-batch span and the other batch's span are both unmatched before repair")
  local after = conform(deepcopy(before))
  Assert.equal(#junctions(after), 0, "both spans are repaired to closure")
  Assert.equal(countAt({ after[1] }, -2, 1, 14), 2, "the first batch expresses the shared breakpoint twice")
  Assert.equal(countAt({ after[2] }, -2, 1, 14), 1, "the second batch expresses the shared breakpoint once")
  Assert.equal(#after[1].indices, 9, "the first batch splits one triangle in two")
  Assert.equal(#after[2].indices, 6, "the second batch splits one triangle in two")
  for index, batch in ipairs(after) do
    for _, area in ipairs(triangleAreas(batch)) do
      Assert.isTrue(math.abs(area) > 1e-12, "retriangulation emits no zero-area triangle in batch " .. index)
    end
  end
  Assert.deepEqual(conform(deepcopy(before)), after, "the same crossing seam conforms identically across runs")
end

-- Three triangles sharing one geometric edge A-B: a count-3 edge is never
-- a spanning edge, so repair tolerates it and leaves the batch untouched,
-- and diagnostics report no spurious junction for it.
local function tripleEdgeFixture()
  return {
    B({
      V(0, 1, 0),
      V(0, 1, 4),
      V(4, 1, 2),
      V(-4, 1, 2),
      V(4, 1, 6),
    }, { 0, 1, 2, 0, 1, 3, 0, 1, 4 }),
  }
end

function T.leaves_a_triple_shared_edge_untouched()
  local input = tripleEdgeFixture()
  local snapshot = deepcopy(input)
  local after = conform(input)
  Assert.deepEqual(after, snapshot, "an overused edge is tolerated: the batch is unchanged")
  Assert.deepEqual(input, snapshot, "conformance leaves the tolerated input untouched")
end

function T.diagnostics_report_no_spurious_junction_for_a_triple_shared_edge()
  local input = tripleEdgeFixture()
  local snapshot = deepcopy(input)
  Assert.equal(#junctions(input), 0, "an overused edge is not a spanning edge: no junction is reported")
  Assert.deepEqual(input, snapshot, "diagnostics leave the tolerated input unchanged")
end

function T.conforming_twice_changes_nothing()
  local once = conform(deepcopy(singleSeam()))
  local twice = conformer().conform(once, context()) or once
  Assert.equal(#twice[1].vertices, #once[1].vertices, "a second conform adds no vertices")
  Assert.equal(#twice[1].indices, #once[1].indices, "a second conform adds no indices")
  Assert.equal(#twice[2].vertices, #once[2].vertices, "a second conform adds no vertices")
  Assert.equal(#twice[2].indices, #once[2].indices, "a second conform adds no indices")
  Assert.equal(#junctions(twice), 0, "the conformed result stays clean")
end

function T.repeated_runs_serialize_identically()
  local first = conform(deepcopy(unionSeam()))
  local second = conform(deepcopy(unionSeam()))
  Assert.deepEqual(second, first, "repeated runs produce identical batch tables")
  for i, batch in ipairs(first) do
    Assert.equal(
      Hashing.sha1hex(MeshWriter.encode(batch)),
      Hashing.sha1hex(MeshWriter.encode(second[i])),
      "repeated runs hash identically per batch"
    )
  end
end

-- The repair is driven by boundary topology alone: unusual material labels
-- must not change the outcome. This locks that production takes no
-- per-material branch for any particular map or exemplar.
function T.repairs_regardless_of_material_identity()
  local input = singleSeam(9)
  input[2].materialIndex = 5
  local after = conform(input)
  Assert.equal(#junctions(after), 0, "repair applies independent of material labels")
  Assert.equal(countAt(after, 0, 1, 2), 2, "the shared breakpoint is expressed on both sides")
end

return { tests = T }
