-- Tests for SceneAssembly, the one submission-order owner for the flattened
-- scene: it concatenates the parts -- map, buildings, neighbours, actors --
-- in desired source order and returns the original item tables, so the flat
-- list position IS the deterministic submission order and repeated per-frame
-- assembly never copies or stamps the producers' persistent draw records.
-- Equal-depth translucent ties are resolved by flat-list position, so
-- cross-group tie order is decided here and nowhere else.

local Assert = require("tests.support.Assert")
local SceneAssembly = require("libs.engine.src.SceneAssembly")
local RenderQueue = require("libs.engine.src.RenderQueue")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function item(id, mode)
  return {
    id = id,
    alphaClass = mode,
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
end

function T.preserves_part_source_order_in_the_flat_list()
  local flat = SceneAssembly.flatten({
    { item("map-a", "opaque"), item("map-b", "opaque") },
    { item("building", "cutout") },
    { item("neighbor-a", "translucent"), item("neighbor-b", "translucent") },
    { item("actor", "translucent") },
  })
  Assert.equal(#flat, 6)
  Assert.equal(flat[1].id, "map-a")
  Assert.equal(flat[2].id, "map-b")
  Assert.equal(flat[3].id, "building")
  Assert.equal(flat[4].id, "neighbor-a")
  Assert.equal(flat[5].id, "neighbor-b")
  Assert.equal(flat[6].id, "actor")
end

function T.empty_parts_yield_an_empty_list()
  Assert.deepEqual(SceneAssembly.flatten({}), {})
  Assert.deepEqual(SceneAssembly.flatten({ {}, {} }), {})
end

-- Repeated assembly must not add or change fields on the producers'
-- persistent draw records (the RenderQueue no-mutation principle applies to
-- the whole ordering pipeline, not just the queue).
function T.flatten_does_not_mutate_input_items()
  local items = { item("a", "opaque"), item("b", "translucent") }
  local before = {}
  for i, it in ipairs(items) do
    before[i] = {}
    for k, v in pairs(it) do
      before[i][k] = v
    end
  end
  SceneAssembly.flatten({ items })
  SceneAssembly.flatten({ items })
  for i, it in ipairs(items) do
    Assert.deepEqual(it, before[i], "input item " .. i .. " mutated by assembly")
  end
end

-- flatten returns the original item tables with no per-record copies or
-- submission stamps; the flat list position is the deterministic
-- tie-breaker, so nothing needs to be written back onto the producers.
function T.flatten_returns_the_original_items()
  local map = item("map", "opaque")
  local actor = item("actor", "translucent")
  local flat = SceneAssembly.flatten({ { map }, { actor } })
  Assert.isTrue(flat[1] == map, "flatten returns the original draw items, not copies")
  Assert.isTrue(flat[2] == actor, "flatten returns the original draw items, not copies")
  Assert.isNil(rawget(flat[1], "submissionIndex"), "no submission number is stamped onto the items")
end

-- Two translucent draws at the same camera depth tie-break by flat-list
-- position: the earlier part (map geometry) draws before the later part
-- (actors) regardless of the flat list's creation order.
function T.equal_depth_translucent_ties_follow_flat_list_order()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local map = item("map", "translucent")
  local neighbor = item("neighbor", "translucent")
  local actor = item("actor", "translucent")
  local flat = SceneAssembly.flatten({
    { map },
    { neighbor },
    { actor },
  })
  local queue = RenderQueue.build(flat, view)
  Assert.equal(#queue.translucent, 3)
  Assert.equal(queue.translucent[1].id, "map")
  Assert.equal(queue.translucent[2].id, "neighbor")
  Assert.equal(queue.translucent[3].id, "actor")
end

-- The assembled order also drives the opaque/cutout/wireframe pass order.
function T.opaque_passes_preserve_assembly_order()
  local flat = SceneAssembly.flatten({
    { item("neighbor", "opaque") },
    { item("map", "opaque") },
    { item("actor", "opaque") },
  })
  local queue = RenderQueue.build(flat, Matrix4.identity())
  Assert.equal(queue.opaque[1].id, "neighbor")
  Assert.equal(queue.opaque[2].id, "map")
  Assert.equal(queue.opaque[3].id, "actor")
end

return T
